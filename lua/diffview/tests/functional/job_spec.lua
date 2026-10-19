local async = require('diffview.async')
local helpers = require('diffview.tests.helpers')
local Job = require('diffview.job').Job
local stub = require('luassert.stub')

local await = async.await
local async_test, eq = helpers.async_test, helpers.eq
local uv = vim.uv

describe('diffview.job', function()
  describe('completion ordering', function()
    local attempts, spawn_stub, pipe_stub

    local function new_handle()
      return {
        closing = false,
        is_closing = function(self) return self.closing end,
        close = function(self) self.closing = true end,
      }
    end

    before_each(function()
      attempts = {}
      pipe_stub = stub(uv, 'new_pipe', function()
        local pipe = new_handle()
        function pipe:read_start(reader)
          self.reader = reader
          self.reading = true
        end
        function pipe:read_stop() self.reading = false end
        function pipe:emit(data)
          if self.reading and not self.closing then self.reader(nil, data) end
        end
        return pipe
      end)
      spawn_stub = stub(uv, 'spawn', function(_, opt, on_exit)
        local handle = new_handle()
        function handle:kill(signal)
          self.killed_with = signal
          return 0
        end
        attempts[#attempts + 1] = {
          handle = handle,
          stdout = opt.stdio[2],
          stderr = opt.stdio[3],
          exit = on_exit,
        }
        return handle, #attempts
      end)
    end)

    after_each(function()
      spawn_stub:revert()
      pipe_stub:revert()
    end)

    local orders = {
      { 'exit', 'stdout', 'stderr' },
      { 'exit', 'stderr', 'stdout' },
      { 'stdout', 'exit', 'stderr' },
      { 'stdout', 'stderr', 'exit' },
      { 'stderr', 'exit', 'stdout' },
      { 'stderr', 'stdout', 'exit' },
    }

    for _, buffered in ipairs({ true, false }) do
      for _, order in ipairs(orders) do
        it(
          ('drains %s output in %s order'):format(
            buffered and 'buffered' or 'line-by-line',
            table.concat(order, ', ')
          ),
          async_test(function()
            local completed, stdout, stderr = 0, {}, {}
            local job = Job({
              command = 'mock',
              buffered_std = buffered,
              log_opt = { silent = true },
              on_exit = function(j, ok)
                eq(true, ok)
                eq(true, j:is_done())
                eq({ 'out', 'last' }, j.stdout)
                eq({ 'err', 'tail' }, j.stderr)
                completed = completed + 1
              end,
            })
            if not buffered then
              job:on_stdout(function(_, line) stdout[#stdout + 1] = line end)
              job:on_stderr(function(_, line) stderr[#stderr + 1] = line end)
            end

            local pending = job:start()
            local attempt = attempts[1]
            for i, event in ipairs(order) do
              if event == 'exit' then
                attempt.exit(0, 0)
                eq(true, attempt.handle.closing)
              elseif event == 'stdout' then
                attempt.stdout:emit('out\nla')
                attempt.stdout:emit('st')
                attempt.stdout:emit(nil)
                eq(true, attempt.stdout.closing)
              else
                attempt.stderr:emit('err\nta')
                attempt.stderr:emit('il')
                attempt.stderr:emit(nil)
                eq(true, attempt.stderr.closing)
              end

              eq(i == 3, pending:is_done())
              eq(i == 3, job:is_done())
              eq(i == 3 and 1 or 0, completed)
            end
            eq(true, await(pending))
            eq(0, job.code)
            eq(0, job.signal)
            if not buffered then
              eq({ 'out', 'last' }, stdout)
              eq({ 'err', 'tail' }, stderr)
            end
          end)
        )
      end
    end

    it(
      'preserves failure output until both streams finish',
      async_test(function()
        local completed = 0
        local job = Job({
          command = 'mock',
          log_opt = { silent = true },
          on_exit = function(_, ok)
            eq(false, ok)
            completed = completed + 1
          end,
        })
        local pending = job:start()
        local attempt = attempts[1]
        attempt.exit(7, 0)
        attempt.stdout:emit('partial output')
        attempt.stdout:emit(nil)
        eq(false, pending:is_done())
        attempt.stderr:emit('failure details')
        attempt.stderr:emit(nil)
        local ok, err = await(pending)
        eq(false, ok)
        eq('Job exited with a non-zero exit code: 7', err)
        eq({ 'partial output' }, job.stdout)
        eq({ 'failure details' }, job.stderr)
        eq(1, completed)
      end)
    )

    it(
      "preserves a killed job's requested status while draining",
      async_test(function()
        local job = Job({ command = 'mock', log_opt = { silent = true } })
        local pending = job:start()
        local attempt = attempts[1]
        eq(0, job:kill(64, 'sigterm'))
        eq('sigterm', attempt.handle.killed_with)
        attempt.exit(0, 15)
        attempt.stdout:emit('last output')
        attempt.stdout:emit(nil)
        attempt.stderr:emit(nil)
        eq(false, await(pending))
        eq(64, job.code)
        eq('sigterm', job.signal)
        eq({ 'last output' }, job.stdout)
      end)
    )

    it(
      'drains each retry before starting a fresh attempt',
      async_test(function()
        local completed, retried = 0, 0
        local job = Job({
          command = 'mock',
          retry = 1,
          fail_cond = Job.FAIL_COND.on_empty,
          log_opt = { silent = true },
          on_retry = function(j)
            eq({}, j.stdout)
            eq({ 'first attempt' }, j.stderr)
            retried = retried + 1
          end,
          on_exit = function() completed = completed + 1 end,
        })
        local pending = job:start()
        local first = attempts[1]
        first.exit(0, 0)
        first.stdout:emit(nil)
        eq(1, #attempts)
        eq(0, retried)
        first.stderr:emit('first attempt')
        first.stderr:emit(nil)
        eq(true, vim.wait(1000, function() return #attempts == 2 end, 1))
        eq(1, retried)
        eq(false, pending:is_done())
        eq(0, completed)

        local second = attempts[2]
        second.stderr:emit(nil)
        second.exit(0, 0)
        eq(false, pending:is_done())
        second.stdout:emit('recovered output')
        second.stdout:emit(nil)
        eq(true, await(pending))
        eq({ 'recovered output' }, job.stdout)
        eq({}, job.stderr)
        eq(1, completed)
      end)
    )
  end)

  describe('real processes', function()
    for _, buffered in ipairs({ true, false }) do
      it(
        ('collects %s output and writes stdin'):format(buffered and 'buffered' or 'line-by-line'),
        async_test(function()
          local job = Job({
            command = vim.v.progpath,
            args = {
              '--headless',
              '-u',
              'NONE',
              '-i',
              'NONE',
              '-n',
              '-c',
              [[lua local data = io.stdin:read('*a'):gsub('\n$', ''); io.stdout:write(data); io.stderr:write('err\ntail')]],
              '-c',
              'qa!',
            },
            writer = 'out\nlast',
            buffered_std = buffered,
            log_opt = { silent = true },
          })
          eq(true, await(job))
          eq({ 'out', 'last' }, job.stdout)
          eq({ 'err', 'tail' }, job.stderr)
        end)
      )
    end

    it('supports synchronous callers', function()
      local job = Job({
        command = vim.v.progpath,
        args = {
          '--headless',
          '-u',
          'NONE',
          '-i',
          'NONE',
          '-n',
          '-c',
          [[lua io.stdout:write('out\nlast')]],
          '-c',
          'qa!',
        },
        log_opt = { silent = true },
      })
      eq(true, job:sync())
      eq({ 'out', 'last' }, job.stdout)
      eq({}, job.stderr)
    end)
  end)
end)
