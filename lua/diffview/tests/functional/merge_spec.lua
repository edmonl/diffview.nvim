local async = require('diffview.async')
local diffview = require('diffview')
local helpers = require('diffview.tests.helpers')
local lib = require('diffview.lib')
local CDiffView = require('diffview.api.views.diff.diff_view').CDiffView
local Diff1 = require('diffview.scene.layouts.diff_1').Diff1
local Diff3Hor = require('diffview.scene.layouts.diff_3_hor').Diff3Hor
local Diff3Ver = require('diffview.scene.layouts.diff_3_ver').Diff3Ver
local Diff4Mixed = require('diffview.scene.layouts.diff_4_mixed').Diff4Mixed
local File = require('diffview.vcs.file').File
local GitAdapter = require('diffview.vcs.adapters.git').GitAdapter
local GitRev = require('diffview.vcs.adapters.git.rev').GitRev
local RevType = require('diffview.vcs.rev').RevType
local utils = require('diffview.utils')
local stub = require('luassert.stub')

local await = async.await
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

diffview.setup({
  use_icons = false,
  watch_index = false,
  view = { merge_tool = { layout = 'diff3_horizontal' } },
})
diffview.init()

describe('merge version availability', function()
  local root, cwd, view, buffers_before, query_count, read_stages, error_stub
  local paths =
    { 'ours-deleted.txt', 'theirs-deleted.txt', 'added.txt', 'modified.txt', 'empty.txt' }

  local function git(...)
    local args = { 'git', '-C', root, '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false' }
    vim.list_extend(args, { ... })
    local result = vim.system(args):wait()
    eq(0, result.code)
    return vim.trim(result.stdout)
  end

  local function commit()
    git('add', '-A')
    git(
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-qm',
      'fixture'
    )
  end

  local function write(path, contents) vim.fn.writefile(contents, root .. '/' .. path) end
  local function wait_for(predicate) eq(true, vim.wait(5000, predicate, 5)) end

  local function entry(path)
    for _, file in ipairs(view.files.conflicting) do
      if file.path == path then return file end
    end
    error('Missing conflicting entry: ' .. path)
  end

  local function select_file(file)
    await(view:set_file(file, false, true))
    eq(file, view.cur_entry)
    for _, win in ipairs(view.cur_layout.windows) do
      eq(true, win:is_file_open())
    end
    await(async.scheduler())
  end

  local function refresh()
    local selected = view.cur_entry
    local updated = false
    view:update_files(function(err)
      eq(nil, err)
      updated = true
    end)
    wait_for(function() return updated end)
    select_file(selected)
  end

  local function open(custom, initial)
    if custom then
      local files = { conflicting = {} }
      for _, path in ipairs(paths) do
        files.conflicting[#files.conflicting + 1] =
          { path = path, status = 'U', selected = path == paths[1] }
      end
      view = CDiffView({
        git_root = root,
        left = GitRev(RevType.STAGE, 0),
        right = GitRev(RevType.LOCAL),
        files = initial and files or nil,
        update_files = function() return files end,
      })
      lib.add_view(view)
    else
      view = lib.diffview_open({})
    end
    eq(true, view.valid)
    view:open()
    wait_for(function() return view.ready and #view.files.conflicting == #paths end)
    wait_for(function() return view.cur_entry and view.cur_layout:is_files_loaded() end)
    select_file(entry(paths[1]))
  end

  local function expected_stages(path)
    local stages = {
      [1] = path ~= 'added.txt' and { 'base ' .. path } or nil,
      [2] = path ~= 'ours-deleted.txt' and { 'ours ' .. path } or nil,
      [3] = path ~= 'theirs-deleted.txt' and { 'theirs ' .. path } or nil,
    }
    if path == 'empty.txt' then stages[2] = {} end
    return stages
  end

  local function assert_versions(file, stages)
    select_file(file)
    for _, win in ipairs(view.cur_layout.windows) do
      local f = win.file
      if f.rev.type == RevType.LOCAL then
        eq(false, f.nulled)
        eq(false, f.bufnr == File.NULL_FILE.bufnr)
        eq(true, vim.bo[f.bufnr].modifiable)
      else
        local contents = stages[f.rev.stage]
        eq(contents == nil, f.nulled)
        eq(contents == nil, f.bufnr == File.NULL_FILE.bufnr)
        eq(
          contents and #contents > 0 and contents or { '' },
          api.nvim_buf_get_lines(f.bufnr, 0, -1, false)
        )
      end
    end
  end

  before_each(function()
    root, cwd = vim.fn.tempname(), vim.fn.getcwd()
    buffers_before, query_count = {}, 0
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      buffers_before[bufnr] = true
    end
    vim.fn.mkdir(root .. '/hooks', 'p')
    git('init', '-q')
    git('config', 'core.hooksPath', root .. '/hooks')
    git('checkout', '-qb', 'ours')
    for _, path in ipairs(paths) do
      if path ~= 'added.txt' then write(path, { 'base ' .. path }) end
    end
    commit()
    git('checkout', '-qb', 'theirs')
    for _, path in ipairs(paths) do
      if path == 'theirs-deleted.txt' then
        vim.fn.delete(root .. '/' .. path)
      else
        write(path, { 'theirs ' .. path })
      end
    end
    commit()
    git('checkout', '-q', 'ours')
    for _, path in ipairs(paths) do
      if path == 'ours-deleted.txt' then
        vim.fn.delete(root .. '/' .. path)
      else
        write(path, path == 'empty.txt' and {} or { 'ours ' .. path })
      end
    end
    commit()
    local merge = vim
      .system({
        'git',
        '-C',
        root,
        '-c',
        'core.hooksPath=' .. root .. '/hooks',
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'merge',
        '--no-edit',
        'theirs',
      })
      :wait()
    eq(1, merge.code)
    -- Leave the editable merge result absent as well as its missing ours stage.
    vim.fn.delete(root .. '/ours-deleted.txt')
    vim.cmd('cd ' .. vim.fn.fnameescape(root))
    read_stages = GitAdapter.get_unmerged_stages
    GitAdapter.get_unmerged_stages = function(self)
      query_count = query_count + 1
      return read_stages(self)
    end
    error_stub = stub(utils, 'err')
  end)

  after_each(function()
    await(async.scheduler())
    GitAdapter.get_unmerged_stages = read_stages
    if view then
      view:close()
      lib.dispose_view(view)
    end
    error_stub:revert()
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

  for _, custom in ipairs({ false, true }) do
    it(
      'preserves missing and empty versions through layout changes and refresh in '
        .. (custom and 'custom' or 'normal')
        .. ' views',
      async_test(function()
        open(custom, true)
        eq(1, query_count)
        local available = {}
        for _, path in ipairs(paths) do
          available[path] = expected_stages(path)
        end
        local show = view.adapter.show
        view.adapter.show = async.wrap(function(self, path, rev, callback)
          -- Missing stages must never reach Git's content loader.
          eq(true, available[path][rev.stage] ~= nil)
          callback(await(show(self, path, rev)))
        end)

        for _, path in ipairs(paths) do
          local file = entry(path)
          local stages = expected_stages(path)
          assert_versions(file, stages)
          for _, layout in ipairs({ Diff4Mixed, Diff1, Diff3Ver, Diff3Hor }) do
            file:convert_layout(layout)
            assert_versions(file, stages)
          end
        end
        eq(1, query_count)

        local added = entry('added.txt')
        local local_file = added.layout.b.file
        api.nvim_buf_set_lines(local_file.bufnr, 0, -1, false, { 'unsaved merge result' })

        -- The base becomes available while hidden in a one-pane layout.
        added:convert_layout(Diff1)
        select_file(added)
        local base = git('rev-parse', ':1:modified.txt')
        local function set_base(hash)
          local result = vim
            .system(
              { 'git', '-C', root, 'update-index', '--index-info' },
              { stdin = '100644 ' .. hash .. ' 1\tadded.txt\n' }
            )
            :wait()
          eq(0, result.code)
        end
        available['added.txt'][1] = { 'base modified.txt' }
        set_base(base)
        refresh()
        eq(2, query_count)
        eq(true, added.merge_stages[1])
        eq(local_file, added.layout.b.file)
        eq({ 'unsaved merge result' }, api.nvim_buf_get_lines(local_file.bufnr, 0, -1, false))

        added:convert_layout(Diff4Mixed)
        select_file(added)
        eq(false, added.layout.d.file.nulled)
        eq({ 'base modified.txt' }, api.nvim_buf_get_lines(added.layout.d.file.bufnr, 0, -1, false))

        -- Refresh must also reconcile panes absent from the configured layout.
        local old_base = added.layout.d.file.bufnr
        local removed = vim
          .system({ 'git', '-C', root, 'update-index', '--index-info' }, {
            stdin = '0 '
              .. string.rep('0', 40)
              .. '\tadded.txt\n'
              .. '100644 '
              .. git('rev-parse', ':2:added.txt')
              .. ' 2\tadded.txt\n'
              .. '100644 '
              .. git('rev-parse', ':3:added.txt')
              .. ' 3\tadded.txt\n',
          })
          :wait()
        eq(0, removed.code)
        available['added.txt'][1] = nil
        refresh()
        eq(3, query_count)
        eq(true, added.layout.d.file.nulled)
        eq(File.NULL_FILE.bufnr, added.layout.d.file.bufnr)
        eq(false, api.nvim_buf_is_valid(old_base))
        eq(local_file, added.layout.b.file)
        eq(true, vim.bo[local_file.bufnr].modified)

        -- Resolve a conflict after the normal status query (or the custom
        -- provider's snapshot) but before reading index-stage availability.
        local query = view.adapter.get_unmerged_stages
        view.adapter.get_unmerged_stages = function(self)
          git('add', '--', 'modified.txt')
          return query(self)
        end
        refresh()
        eq(4, query_count)
        eq(4, #view.files.conflicting)
        for _, file in ipairs(view.files.conflicting) do
          eq(false, file.path == 'modified.txt')
        end
        eq(0, #error_stub.calls)
      end)
    )
  end

  it(
    'reads NUL-delimited stages for paths containing tabs and line breaks',
    async_test(function()
      open(false)
      local path = 'odd\tname\r\n.txt'
      local blob = git('rev-parse', ':2:added.txt')
      local result = vim
        .system({ 'git', '-C', root, 'update-index', '-z', '--index-info' }, {
          stdin = '100644 ' .. blob .. ' 2\t' .. path .. '\0',
        })
        :wait()
      eq(0, result.code)
      local err, stages = view.adapter:get_unmerged_stages()
      eq(nil, err)
      eq({ [2] = true }, stages[path])
      for _, name in ipairs(paths) do
        for stage in pairs(expected_stages(name)) do
          eq(true, stages[name][stage])
        end
      end
    end)
  )

  it(
    'reports failed stage queries instead of treating versions as absent',
    async_test(function()
      open(true)
      local original = entry('added.txt')
      local old_file = original.layout.a.file
      GitAdapter.get_unmerged_stages = function() return { 'stage query failed' } end
      local err = await(view:get_updated_files())
      eq({ 'stage query failed' }, err)
      eq(original, entry('added.txt'))
      eq(old_file, original.layout.a.file)

      -- Exercise the Git command failure path without changing its configured executable.
      local get_command = view.adapter.get_command
      view.adapter.get_command = function() return { 'git', '--git-dir=' .. root .. '/missing' } end
      local query_err, stages = read_stages(view.adapter)
      eq(nil, stages)
      eq('Failed to read unmerged index stages!', query_err[1])
      view.adapter.get_command = get_command
    end)
  )
end)
