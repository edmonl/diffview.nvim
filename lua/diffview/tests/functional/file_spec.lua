local async = require('diffview.async')
local helpers = require('diffview.tests.helpers')
local File = require('diffview.vcs.file').File
local GitRev = require('diffview.vcs.adapters.git.rev').GitRev
local RevType = require('diffview.vcs.rev').RevType
local utils = require('diffview.utils')
local Diff2 = require('diffview.scene.layouts.diff_2').Diff2

local await, pawait = async.await, async.pawait
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

describe('diffview.vcs.file', function()
  local adapter, requests, buffers, windows, paths

  before_each(function()
    requests, buffers, windows, paths = {}, {}, {}, {}
    adapter = {
      ctx = { toplevel = '/diffview-file-tests', dir = '/diffview-file-tests/.git' },
      show = async.wrap(function(_, _, _, callback) requests[#requests + 1] = callback end),
      file_blob_hash = function() return 'index-blob' end,
    }
  end)

  after_each(function()
    for _, winid in ipairs(windows) do
      if api.nvim_win_is_valid(winid) then api.nvim_win_close(winid, true) end
    end
    for _, bufnr in ipairs(buffers) do
      if api.nvim_buf_is_valid(bufnr) then api.nvim_buf_delete(bufnr, { force = true }) end
    end
    File.index_bufmap[adapter.ctx.toplevel] = nil
    for _, path in ipairs(paths) do
      vim.fn.delete(path)
    end
  end)

  local function new_file(rev, path)
    return File({
      adapter = adapter,
      path = path or 'tracked.txt',
      kind = 'staged',
      binary = false,
      rev = rev or GitRev(RevType.COMMIT, string.rep('a', 40)),
    })
  end

  local function start_load(file)
    local load = {}
    load.future = async.void(function()
      load.ok, load.result = pawait(file.create_buffer, file)
    end)()
    await(async.scheduler())
    load.bufnr = file.bufnr
    load.request = requests[#requests]
    buffers[#buffers + 1] = load.bufnr
    return load
  end

  local function check_load(load, expected_error)
    await(load.future)
    if expected_error then
      eq(false, load.ok)
      eq(true, load.result:find(expected_error, 1, true) ~= nil)
    else
      eq(true, load.ok)
      eq(load.bufnr, load.result)
    end
  end

  local function finish_load(load, err, lines, expected_error)
    -- Async error propagation can also raise through the producer callback.
    local ok, callback_err = pcall(load.request, err, lines)
    check_load(load, expected_error)
    if not ok then
      if not expected_error then error(callback_err) end
      eq(true, callback_err:find(expected_error, 1, true) ~= nil)
    end
  end

  local function new_window(file)
    local bufnr = api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = bufnr
    local winid = api.nvim_open_win(bufnr, false, {
      relative = 'editor',
      row = 0,
      col = 0,
      width = 20,
      height = 5,
    })
    windows[#windows + 1] = winid
    local layout = Diff2({ a = file, b = File.NULL_FILE, winid_a = winid })
    file.active = true
    return layout.a
  end

  for _, reuse_file in ipairs({ true, false }) do
    it(
      ('retries a failed load using %s'):format(reuse_file and 'the same file' or 'a new file'),
      async_test(function()
        local file = new_file()
        local failed = start_load(file)
        local name = api.nvim_buf_get_name(failed.bufnr)
        finish_load(failed, { 'git show failed' }, nil, 'git show failed')
        eq(nil, file.bufnr)
        eq(false, api.nvim_buf_is_valid(failed.bufnr))
        eq(nil, utils.find_named_buffer(name))

        local retry_file = reuse_file and file or new_file()
        local retry = start_load(retry_file)
        eq(2, #requests)
        finish_load(retry, nil, { 'original contents' })
        eq({ 'original contents' }, api.nvim_buf_get_lines(retry.bufnr, 0, -1, false))
        eq(false, vim.bo[retry.bufnr].modifiable)
        eq('nowrite', vim.bo[retry.bufnr].buftype)
      end)
    )
  end

  it(
    'cleans up when the data producer raises an error',
    async_test(function()
      local show = adapter.show
      adapter.show = async.void(function(self, path, rev)
        await(show(self, path, rev))
        error('producer raised an error')
      end)
      local file = new_file()
      local load = start_load(file)
      finish_load(load, nil, {}, 'producer raised an error')
      eq(nil, file.bufnr)
      eq(false, api.nvim_buf_is_valid(load.bufnr))
    end)
  )

  it(
    'cleans up a failed load delivered in a fast event',
    async_test(function()
      local file = new_file()
      local load = start_load(file)
      local name = api.nvim_buf_get_name(load.bufnr)
      local was_fast = false
      local timer = vim.loop.new_timer()
      timer:start(0, 0, function()
        timer:stop()
        timer:close()
        was_fast = vim.in_fast_event()
        pcall(load.request, { 'fast-event load failure' })
      end)
      check_load(load, 'fast-event load failure')
      eq(true, was_fast)
      eq(nil, file.bufnr)
      eq(false, api.nvim_buf_is_valid(load.bufnr))
      eq(nil, utils.find_named_buffer(name))
    end)
  )

  for _, method in ipairs({ 'dispose_buffer', 'destroy' }) do
    it(
      ('rejects a load after %s'):format(method),
      async_test(function()
        local file = new_file()
        local load = start_load(file)
        file[method](file)
        eq(false, api.nvim_buf_is_valid(load.bufnr))
        finish_load(load, nil, { 'outdated contents' }, 'The buffer has been invalidated!')
        eq(nil, file.bufnr)
      end)
    )
  end

  for _, failed in ipairs({ false, true }) do
    it(
      ('preserves a replacement buffer when the old load %s'):format(
        failed and 'fails' or 'succeeds'
      ),
      async_test(function()
        local file = new_file()
        local old = start_load(file)
        file:dispose_buffer()
        local replacement = start_load(file)
        finish_load(replacement, nil, { 'replacement contents' })

        if failed then
          finish_load(old, { 'old load failed' }, nil, 'old load failed')
        else
          finish_load(old, nil, { 'outdated contents' }, 'The buffer has been invalidated!')
        end
        eq(replacement.bufnr, file.bufnr)
        eq(true, api.nvim_buf_is_valid(replacement.bufnr))
        eq({ 'replacement contents' }, api.nvim_buf_get_lines(replacement.bufnr, 0, -1, false))
        eq(false, vim.bo[replacement.bufnr].modifiable)
      end)
    )
  end

  it(
    'keeps index buffers editable and registered after loading',
    async_test(function()
      local file = new_file(GitRev(RevType.STAGE, 0))
      local load = start_load(file)
      finish_load(load, nil, { 'index contents' })
      eq(true, vim.bo[load.bufnr].modifiable)
      eq('', vim.bo[load.bufnr].buftype)
      eq('index-blob', file.blob_hash)
      eq(load.bufnr, File.index_bufmap[adapter.ctx.toplevel][file.path])
    end)
  )

  it(
    'cleans up index registration when buffer setup fails',
    async_test(function()
      local file = new_file(GitRev(RevType.STAGE, 0))
      file.post_buf_created = function() error('buffer setup failed') end
      local load = start_load(file)
      finish_load(load, nil, { 'index contents' }, 'buffer setup failed')
      eq(nil, file.bufnr)
      eq(nil, file.blob_hash)
      eq(false, api.nvim_buf_is_valid(load.bufnr))
      eq(nil, File.index_bufmap[adapter.ctx.toplevel][file.path])

      file.post_buf_created = nil
      local retry = start_load(file)
      finish_load(retry, nil, { 'recovered index contents' })
      eq(retry.bufnr, File.index_bufmap[adapter.ctx.toplevel][file.path])
      eq('index-blob', file.blob_hash)
      eq(true, vim.bo[retry.bufnr].modifiable)
    end)
  )

  for _, same_file in ipairs({ true, false }) do
    for _, stage in ipairs({ false, true }) do
      it(
        ('shares a pending %s load with %s'):format(
          stage and 'index' or 'commit',
          same_file and 'the same file' or 'another file'
        ),
        async_test(function()
          local rev = stage and GitRev(RevType.STAGE, 0) or nil
          local first_file = new_file(rev)
          local first = start_load(first_file)
          local second_file = same_file and first_file or new_file(rev)
          local second = start_load(second_file)
          eq(1, #requests)
          eq(first.bufnr, second.bufnr)
          eq(true, first_file:is_valid())
          eq(false, first_file:is_ready())
          eq(false, first.future:is_done())
          eq(false, second.future:is_done())

          finish_load(first, nil, { 'shared contents' })
          check_load(second)
          eq(true, first_file:is_ready())
          eq(true, second_file:is_ready())
          eq({ 'shared contents' }, api.nvim_buf_get_lines(second.bufnr, 0, -1, false))
          eq(stage and 'index-blob' or nil, second_file.blob_hash)

          local reused_file = new_file(rev)
          local reused = start_load(reused_file)
          check_load(reused)
          eq(1, #requests)
          eq(first.bufnr, reused.bufnr)
          eq(true, reused_file:is_ready())
          eq(first_file.blob_hash, reused_file.blob_hash)
        end)
      )
    end
  end

  it(
    'notifies all callers of a shared failure and permits retry',
    async_test(function()
      local files = { new_file(), new_file(), new_file() }
      local loads = {}
      for i, file in ipairs(files) do
        loads[i] = start_load(file)
      end
      eq(1, #requests)
      finish_load(loads[1], { 'shared failure' }, nil, 'shared failure')
      for i, file in ipairs(files) do
        check_load(loads[i], 'shared failure')
        eq(nil, file.bufnr)
        eq(false, file:is_ready())
      end
      local retry = start_load(files[2])
      eq(2, #requests)
      finish_load(retry, nil, { 'recovered contents' })
      eq(true, files[2]:is_ready())
    end)
  )

  it(
    'clears a deleted shared buffer from the cache',
    async_test(function()
      local file = new_file()
      local first = start_load(file)
      finish_load(first, nil, { 'original contents' })
      api.nvim_buf_delete(first.bufnr, { force = true })
      eq(false, file:is_ready())
      local replacement = start_load(file)
      eq(2, #requests)
      finish_load(replacement, nil, { 'replacement contents' })
      eq(true, file:is_ready())
    end)
  )

  it(
    'reloads an unloaded shared buffer',
    async_test(function()
      local file = new_file()
      local first = start_load(file)
      finish_load(first, nil, { 'original contents' })
      api.nvim_buf_delete(first.bufnr, { unload = true })
      eq(true, file:is_valid())
      eq(false, file:is_ready())
      local replacement = start_load(file)
      eq(2, #requests)
      finish_load(replacement, nil, { 'replacement contents' })
      eq(true, file:is_ready())
    end)
  )

  it(
    'preserves a newer shared load when a cancelled load finishes',
    async_test(function()
      local file = new_file()
      local old = start_load(file)
      local peer_file = new_file()
      local peer = start_load(peer_file)
      file:dispose_buffer()
      local replacement_file = new_file()
      local replacement = start_load(replacement_file)
      eq(2, #requests)
      finish_load(old, nil, { 'outdated contents' }, 'The buffer has been invalidated!')
      check_load(peer, 'The buffer has been invalidated!')
      eq(nil, peer_file.bufnr)
      eq(replacement.bufnr, replacement_file.bufnr)
      finish_load(replacement, nil, { 'replacement contents' })
      local reused = start_load(new_file())
      check_load(reused)
      eq(replacement.bufnr, reused.bufnr)
      eq(2, #requests)
    end)
  )

  it(
    'loads local files and reloads unloaded local buffers',
    async_test(function()
      local path = vim.fn.tempname()
      paths[#paths + 1] = path
      vim.fn.writefile({ 'working tree contents' }, path)
      local file = new_file(GitRev(RevType.LOCAL), path)
      local first = start_load(file)
      check_load(first)
      eq(true, file:is_ready())
      eq({ 'working tree contents' }, api.nvim_buf_get_lines(first.bufnr, 0, -1, false))
      api.nvim_buf_delete(first.bufnr, { unload = true })
      eq(false, file:is_ready())
      local reloaded = start_load(file)
      check_load(reloaded)
      eq(true, file:is_ready())
      eq({ 'working tree contents' }, api.nvim_buf_get_lines(reloaded.bufnr, 0, -1, false))
      eq(0, #requests)
    end)
  )

  it(
    'treats successfully loaded empty contents as ready',
    async_test(function()
      local file = new_file()
      local load = start_load(file)
      finish_load(load, nil, {})
      eq({ '' }, api.nvim_buf_get_lines(load.bufnr, 0, -1, false))
      eq(true, file:is_ready())
    end)
  )

  for _, kind in ipairs({ 'null', 'nulled', 'binary' }) do
    it(
      ('marks %s buffers ready without fetching contents'):format(kind),
      async_test(function()
        local file = kind == 'null' and File.NULL_FILE or new_file()
        if kind == 'nulled' then file.nulled = true end
        if kind == 'binary' then file.binary = true end
        local load = start_load(file)
        check_load(load)
        eq(true, file:is_ready())
        eq(0, #requests)
      end)
    )
  end

  it(
    'makes window loading await an existing unfinished buffer',
    async_test(function()
      local file = new_file()
      local load = start_load(file)
      local win = new_window(file)
      local pending = win:load_file()
      await(async.scheduler())
      eq(false, pending:is_done())
      finish_load(load, nil, { 'original contents' })
      eq(true, await(pending))
      eq(1, #requests)
    end)
  )

  it(
    'opens a window only after its file is ready',
    async_test(function()
      local file = new_file()
      local load = start_load(file)
      local win = new_window(file)
      local previous = api.nvim_win_get_buf(win.id)
      local pending = win:open_file()
      await(async.scheduler())
      eq(false, pending:is_done())
      eq(previous, api.nvim_win_get_buf(win.id))
      eq(false, win:is_file_open())
      finish_load(load, nil, { 'original contents' })
      await(pending)
      eq(load.bufnr, api.nvim_win_get_buf(win.id))
      eq(true, win:is_file_open())
    end)
  )

  it(
    'does not open an outdated file when the window changes during loading',
    async_test(function()
      local old_file = new_file()
      local load = start_load(old_file)
      local win = new_window(old_file)
      local previous = api.nvim_win_get_buf(win.id)
      local pending = win:open_file()
      await(async.scheduler())
      local replacement = new_file(nil, 'replacement.txt')
      replacement.active = true
      win:set_file(replacement)
      finish_load(load, nil, { 'outdated contents' })
      await(pending)
      eq(previous, api.nvim_win_get_buf(win.id))
      eq(false, win:is_file_open())
    end)
  )

  it(
    'keeps a ready replacement open when an older window request fails',
    async_test(function()
      local file = new_file()
      local old = start_load(file)
      local win = new_window(file)
      local pending = win:open_file()
      await(async.scheduler())
      file:dispose_buffer()
      local replacement = start_load(file)
      finish_load(replacement, nil, { 'replacement contents' })
      finish_load(old, nil, { 'outdated contents' }, 'The buffer has been invalidated!')
      await(pending)
      eq(replacement.bufnr, api.nvim_win_get_buf(win.id))
      eq(true, win:is_file_open())
    end)
  )

  it(
    'reports layout readiness only after every file has loaded',
    async_test(function()
      local first_file = new_file()
      local second_file = new_file(nil, 'other.txt')
      local first = start_load(first_file)
      local second = start_load(second_file)
      local layout = Diff2({ a = first_file, b = second_file })
      eq(false, layout:is_files_loaded())
      finish_load(first, nil, { 'first contents' })
      eq(false, layout:is_files_loaded())
      finish_load(second, nil, { 'second contents' })
      eq(true, layout:is_files_loaded())
    end)
  )

  it(
    'opens layout windows and emits files_opened only after loading',
    async_test(function()
      local first_file = new_file()
      local second_file = new_file(nil, 'other.txt')
      local first = start_load(first_file)
      local second = start_load(second_file)
      local first_win = new_window(first_file)
      local second_win = new_window(second_file)
      local layout = Diff2({
        a = first_file,
        b = second_file,
        winid_a = first_win.id,
        winid_b = second_win.id,
      })
      local opened = 0
      layout.emitter:on('files_opened', function()
        eq(true, layout:is_files_loaded())
        eq(true, layout.a:is_file_open())
        eq(true, layout.b:is_file_open())
        opened = opened + 1
      end)
      local pending = layout:open_files()
      await(async.scheduler())
      eq(false, pending:is_done())
      finish_load(first, nil, { 'first contents' })
      eq(0, opened)
      finish_load(second, nil, { 'second contents' })
      await(pending)
      eq(1, opened)
      eq(2, #requests)
    end)
  )
end)
