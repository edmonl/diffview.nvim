local async = require('diffview.async')
local helpers = require('diffview.tests.helpers')
local File = require('diffview.vcs.file').File
local GitRev = require('diffview.vcs.adapters.git.rev').GitRev
local RevType = require('diffview.vcs.rev').RevType
local utils = require('diffview.utils')

local await, pawait = async.await, async.pawait
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

describe('diffview.vcs.file', function()
  local adapter, requests, buffers

  before_each(function()
    requests, buffers = {}, {}
    adapter = {
      ctx = { toplevel = '/diffview-file-tests', dir = '/diffview-file-tests/.git' },
      show = async.wrap(function(_, _, _, callback) requests[#requests + 1] = callback end),
      file_blob_hash = function() return 'index-blob' end,
    }
  end)

  after_each(function()
    for _, bufnr in ipairs(buffers) do
      if api.nvim_buf_is_valid(bufnr) then api.nvim_buf_delete(bufnr, { force = true }) end
    end
    File.index_bufmap[adapter.ctx.toplevel] = nil
  end)

  local function new_file(rev)
    return File({
      adapter = adapter,
      path = 'tracked.txt',
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

  local function finish_load(load, err, lines, expected_error)
    -- Async error propagation can also raise through the producer callback.
    local ok, callback_err = pcall(load.request, err, lines)
    await(load.future)
    if expected_error then
      eq(false, load.ok)
      eq(true, load.result:find(expected_error, 1, true) ~= nil)
      if not ok then eq(true, callback_err:find(expected_error, 1, true) ~= nil) end
    else
      if not ok then error(callback_err) end
      eq(true, load.ok)
      eq(load.bufnr, load.result)
    end
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
end)
