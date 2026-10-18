local async = require('diffview.async')
local diffview = require('diffview')
local helpers = require('diffview.tests.helpers')
local lib = require('diffview.lib')
local File = require('diffview.vcs.file').File
local RevType = require('diffview.vcs.rev').RevType
local utils = require('diffview.utils')
local stub = require('luassert.stub')

local await = async.await
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

diffview.setup({ use_icons = false, watch_index = false })
diffview.init()

describe('staging integration', function()
  local root, cwd, view, buffers_before, pending, releases, cleaning, error_stub

  local function git(...)
    local args = { 'git', '-C', root, '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false' }
    vim.list_extend(args, { ... })
    local out = vim.fn.systemlist(args)
    eq(0, vim.v.shell_error)
    return out
  end

  local function wait_for(predicate) eq(true, vim.wait(5000, predicate, 5)) end

  local function track(future)
    pending[#pending + 1] = future
    return future
  end

  local function finish(future)
    wait_for(function() return future:is_done() end)
    await(future)
  end

  local function settle()
    wait_for(function()
      for _, future in ipairs(pending) do
        if not future:is_done() then return false end
      end
      return true
    end)
    for _, future in ipairs(pending) do
      eq(nil, future.err)
    end
  end

  local function entry(kind, path)
    for _, file in ipairs(view.files[kind]) do
      if file.path == path then return file end
    end
  end

  local function assert_contents(path, kind)
    eq(path, view.cur_entry.path)
    eq(kind, view.cur_entry.kind)
    eq(true, view.cur_layout:is_files_loaded())
    eq(true, view.cur_layout.a:is_file_open())
    eq(true, view.cur_layout.b:is_file_open())
    local a, b = view.cur_layout.a.file, view.cur_layout.b.file
    eq({ 'original ' .. path, 'context' }, api.nvim_buf_get_lines(a.bufnr, 0, -1, false))
    eq({ 'modified ' .. path, 'context' }, api.nvim_buf_get_lines(b.bufnr, 0, -1, false))
    if kind == 'staged' then
      eq(RevType.COMMIT, a.rev.type)
      eq(RevType.STAGE, b.rev.type)
    end
  end

  local function select_file(kind, path)
    local file = entry(kind, path)
    eq(true, file ~= nil)
    finish(track(view:set_file(file, false, true)))
    assert_contents(path, kind)
  end

  local function refresh()
    local updated = false
    view:update_files(function(err)
      eq(nil, err)
      updated = true
    end)
    wait_for(function() return updated end)
  end

  local function revisit_staged_file()
    refresh()
    select_file('working', 'b.txt')
    select_file('staged', 'a.txt')
    settle()
    eq({ 'modified a.txt', 'context' }, git('show', ':a.txt'))
    eq({ 'original a.txt', 'context' }, git('show', 'HEAD:a.txt'))
  end

  -- Gates hold real Git results at the adapter boundary; no timer determines
  -- whether staging happens before or after the pending operation completes.
  local function gate(callback, ...)
    local args = { ... }
    local n = select('#', ...)
    local request = { released = false }
    function request:release(err)
      if self.released then return end
      self.released = true
      if err then
        callback(err)
      else
        callback(unpack(args, 1, n))
      end
    end
    releases[#releases + 1] = function() request:release() end
    return request
  end

  before_each(function()
    cwd, root = vim.fn.getcwd(), vim.fn.tempname()
    pending, releases, cleaning, buffers_before = {}, {}, false, {}
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      buffers_before[bufnr] = true
    end
    vim.fn.mkdir(root .. '/hooks', 'p')
    git('init', '-q')
    git('config', 'core.hooksPath', root .. '/hooks')
    for _, path in ipairs({ 'a.txt', 'b.txt' }) do
      vim.fn.writefile({ 'original ' .. path, 'context' }, root .. '/' .. path)
    end
    git('add', '.')
    git(
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-qm',
      'fixture'
    )
    for _, path in ipairs({ 'a.txt', 'b.txt' }) do
      vim.fn.writefile({ 'modified ' .. path, 'context' }, root .. '/' .. path)
    end
    vim.cmd('cd ' .. vim.fn.fnameescape(root))
    view = lib.diffview_open({ '--selected-file=a.txt' })
    local set_file = view._set_file
    view._set_file = async.void(function(self, file) await(track(set_file(self, file))) end)
    view:open()
    wait_for(function() return view.ready and entry('working', 'a.txt') ~= nil end)
    select_file('working', 'a.txt')
    settle()
  end)

  after_each(function()
    cleaning = true
    for _, release in ipairs(releases) do
      pcall(release)
    end
    vim.wait(5000, function()
      for _, future in ipairs(pending) do
        if not future:is_done() then return false end
      end
      return true
    end, 5)
    if view then
      view:close()
      lib.dispose_view(view)
    end
    if error_stub then
      error_stub:revert()
      error_stub = nil
    end
    await(async.scheduler())
    vim.cmd('cd ' .. vim.fn.fnameescape(cwd))
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if not buffers_before[bufnr] and bufnr ~= File.NULL_FILE.bufnr then
        api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    File.index_bufmap[root] = nil
    vim.fn.delete(root, 'rf')
    view = nil
  end)

  it(
    'stages while index contents are loading and rejects the old completion',
    async_test(function()
      local original_show = view.adapter.show
      local held
      view.adapter.show = async.wrap(function(self, path, rev, callback)
        local err, data = await(original_show(self, path, rev))
        if not cleaning and not held and path == 'a.txt' and rev.type == RevType.STAGE then
          held = gate(callback, err, data)
        else
          callback(err, data)
        end
      end)
      local working = entry('working', 'a.txt')
      working.layout.a.file:dispose_buffer()
      local old_selection = track(view:set_file(working, false, true))
      wait_for(function() return held ~= nil end)
      eq(false, old_selection:is_done())
      view.emitter:emit('toggle_stage_entry')
      wait_for(function() return entry('staged', 'a.txt') ~= nil end)
      select_file('staged', 'a.txt')
      held:release()
      finish(old_selection)
      assert_contents('a.txt', 'staged')
      revisit_staged_file()
    end)
  )

  it(
    'stages while an earlier status refresh is pending',
    async_test(function()
      local original_get = view.get_updated_files
      local held = {}
      view.get_updated_files = async.wrap(function(self, callback)
        local err, files = await(original_get(self))
        if not cleaning and #held < 2 then
          held[#held + 1] = gate(callback, err, files)
        else
          callback(err, files)
        end
      end)
      local old_updated = false
      view:update_files(function(err)
        eq(nil, err)
        old_updated = true
      end)
      wait_for(function() return #held == 1 end)
      view.emitter:emit('toggle_stage_entry')
      wait_for(function() return #held == 2 end)
      eq(false, old_updated)
      held[1]:release()
      wait_for(function() return old_updated end)
      held[2]:release()
      wait_for(function() return entry('staged', 'a.txt') ~= nil end)
      select_file('staged', 'a.txt')
      revisit_staged_file()
    end)
  )

  it(
    'recovers shared staged-buffer failures after refresh and switching files',
    async_test(function()
      view.emitter:emit('toggle_stage_entry')
      wait_for(function() return entry('staged', 'a.txt') ~= nil end)
      select_file('staged', 'a.txt')
      local staged = entry('staged', 'a.txt')
      settle()
      staged.layout.a.file:dispose_buffer()
      local original_show = view.adapter.show
      local held, failing = nil, true
      local reported = {}
      error_stub = stub(utils, 'err', function(message) reported[#reported + 1] = message end)
      view.adapter.show = async.wrap(function(self, path, rev, callback)
        local err, data = await(original_show(self, path, rev))
        if not cleaning and failing and path == 'a.txt' and rev.type == RevType.COMMIT then
          if not held then
            held = gate(callback, err, data)
          else
            callback({ 'injected staged-buffer failure' })
          end
        else
          callback(err, data)
        end
      end)
      local first = track(view:set_file(staged, false, true))
      wait_for(function() return held ~= nil end)
      local second = track(view:set_file(staged, false, true))
      await(async.scheduler())
      eq(false, first:is_done())
      eq(false, second:is_done())
      held:release({ 'injected staged-buffer failure' })
      finish(first)
      finish(second)
      settle()
      eq(nil, staged.layout.a.file.bufnr)
      eq(true, view.cur_layout.a:is_nulled())
      failing = false
      revisit_staged_file()
      eq(true, #reported > 0)
      for _, message in ipairs(reported) do
        eq(1, message:find('Failed to create diff buffer:', 1, true))
      end
    end)
  )
end)
