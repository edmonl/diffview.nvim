local async = require('diffview.async')
local diffview = require('diffview')
local helpers = require('diffview.tests.helpers')
local lib = require('diffview.lib')
local CDiffView = require('diffview.api.views.diff.diff_view').CDiffView
local Diff2Ver = require('diffview.scene.layouts.diff_2_ver').Diff2Ver
local File = require('diffview.vcs.file').File
local GitRev = require('diffview.vcs.adapters.git.rev').GitRev
local RevType = require('diffview.vcs.rev').RevType

local await = async.await
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

diffview.setup({ use_icons = false, watch_index = false })
diffview.init()

describe('custom diff empty sides', function()
  local root, cwd, view, files, calls, buffers_before

  local function git(...)
    local args = { 'git', '-C', root, '-c', 'commit.gpgsign=false' }
    vim.list_extend(args, { ... })
    vim.fn.system(args)
    eq(0, vim.v.shell_error)
  end

  local function wait_for(predicate) eq(true, vim.wait(5000, predicate, 5)) end

  local function select_file()
    await(view:set_file(view.panel.cur_file, false, true))
    eq(true, view.cur_layout.a:is_file_open())
    eq(true, view.cur_layout.b:is_file_open())
    return view.cur_entry
  end

  local function open(kind, data, right)
    files[kind] = { data }
    view = CDiffView({
      git_root = root,
      left = GitRev(RevType.COMMIT, 'HEAD'),
      right = right or GitRev(RevType.STAGE, 0),
      update_files = function() return files end,
      get_file_data = function(section, path, side)
        eq(kind, section)
        eq('tracked.txt', path)
        calls[#calls + 1] = side
        return { 'custom ' .. side }
      end,
    })
    eq(true, view.valid)
    lib.add_view(view)
    view:open()
    wait_for(function() return view.ready and view.files:len() == 1 end)
    return select_file()
  end

  local function refresh()
    local updated = false
    view:update_files(function(err)
      eq(nil, err)
      updated = true
    end)
    wait_for(function() return updated end)
    return select_file()
  end

  local function assert_sides(left_null, right_null)
    for symbol, nulled in pairs({ a = left_null, b = right_null }) do
      local file = view.cur_layout[symbol].file
      eq(nulled, file.nulled)
      eq(nulled, file.bufnr == File.NULL_FILE.bufnr)
      eq(
        nulled and { '' } or { 'custom ' .. (symbol == 'a' and 'left' or 'right') },
        api.nvim_buf_get_lines(file.bufnr, 0, -1, false)
      )
    end
  end

  before_each(function()
    root, cwd = vim.fn.tempname(), vim.fn.getcwd()
    files, calls, buffers_before = {}, {}, {}
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      buffers_before[bufnr] = true
    end
    vim.fn.mkdir(root .. '/hooks', 'p')
    git('init', '-q')
    git('config', 'core.hooksPath', root .. '/hooks')
    vim.fn.writefile({ 'tracked contents' }, root .. '/tracked.txt')
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
    vim.cmd('cd ' .. vim.fn.fnameescape(root))
  end)

  after_each(function()
    if view then
      view:close()
      lib.dispose_view(view)
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

  for _, kind in ipairs({ 'working', 'staged' }) do
    it(
      'reconciles explicit and inferred empty sides for ' .. kind .. ' files',
      async_test(function()
        local data = { path = 'tracked.txt', status = 'A', left_null = false, right_null = true }
        local entry = open(kind, data)
        assert_sides(false, true)
        eq({ 'left' }, calls)
        local old_left = entry.layout.a.file
        local old_buffer = old_left.bufnr

        data.status, data.left_null, data.right_null = 'D', true, false
        eq(entry, refresh())
        assert_sides(true, false)
        eq({ 'left', 'right' }, calls)
        eq(false, api.nvim_buf_is_valid(old_buffer))
        eq(false, old_left.active)
        local right = entry.layout.b.file

        entry:convert_layout(Diff2Ver)
        select_file()
        assert_sides(true, false)
        eq(right, entry.layout.b.file)
        eq({ 'left', 'right' }, calls)

        -- Removing overrides restores status inference without reloading
        -- a side whose effective empty state has not changed.
        data.status, data.left_null, data.right_null = 'M', nil, nil
        eq(entry, refresh())
        assert_sides(false, false)
        eq(right, entry.layout.b.file)
        eq({ 'left', 'right', 'left' }, calls)

        data.status = 'A'
        refresh()
        assert_sides(true, false)
        eq(right, entry.layout.b.file)

        data.status = 'D'
        refresh()
        assert_sides(false, true)
        eq({ 'left', 'right', 'left', 'left' }, calls)
      end)
    )
  end

  it(
    'preserves unsaved working-tree contents when hiding and restoring that side',
    async_test(function()
      local data = { path = 'tracked.txt', status = 'M', right_null = false }
      local entry = open('working', data, GitRev(RevType.LOCAL))
      local left, right = entry.layout.a.file, entry.layout.b.file
      local bufnr = right.bufnr
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'unsaved contents' })

      data.right_null = true
      refresh()
      eq(File.NULL_FILE.bufnr, entry.layout.b.file.bufnr)
      eq(true, api.nvim_buf_is_valid(bufnr))
      eq(true, vim.bo[bufnr].modified)
      eq(left, entry.layout.a.file)

      data.right_null = false
      refresh()
      eq(bufnr, entry.layout.b.file.bufnr)
      eq({ 'unsaved contents' }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
      eq(true, vim.bo[bufnr].modified)
      eq(left, entry.layout.a.file)
      eq({ 'left' }, calls)
    end)
  )
end)
