local async = require('diffview.async')
local helpers = require('diffview.tests.helpers')
local vcs = require('diffview.vcs')
local line_history = require('diffview.vcs.adapters.git.line_history')
local stub = require('luassert.stub')
local Diff2Hor = require('diffview.scene.layouts.diff_2_hor').Diff2Hor
local File = require('diffview.vcs.file').File
local GitRev = require('diffview.vcs.adapters.git.rev').GitRev
local JobStatus = require('diffview.vcs.utils').JobStatus

local await = async.await
local async_test, eq = helpers.async_test, helpers.eq
local api = vim.api

describe('Git line-history patches', function()
  local root, adapter, buffers_before, initial, parse_stub
  local edited = { 'before', 'ONE', 'stable', 'TWO', 'after', 'tail' }

  local function run_git(...)
    local args = { 'git', '-C', root, '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false' }
    vim.list_extend(args, { ... })
    return vim.system(args):wait()
  end

  local function git(...)
    local result = run_git(...)
    eq(0, result.code)
    local lines = vim.split(result.stdout, '\n', { plain = true })
    if lines[#lines] == '' then lines[#lines] = nil end
    return lines
  end

  local function write(path, contents, no_eol)
    vim.fn.writefile(contents, root .. '/' .. path, no_eol and 'b' or '')
  end

  local function commit(message)
    git('add', '-A')
    git('commit', '-qm', message)
  end

  local function trace(...)
    local lines = git(
      '-c',
      'core.quotePath=false',
      'log',
      '-n1',
      '--color=never',
      '--no-ext-diff',
      '--format=%H %P',
      ...
    )
    local patches, err = line_history.parse(vim.list_slice(lines, 2))
    eq(nil, err)
    return patches, vim.split(lines[1], ' ', { trimempty = true }), lines
  end

  -- Assert only the paths and coordinates consumed by line history and folds;
  -- the parser's unused patch metadata and content storage can change freely.
  local function coordinates(patch)
    local hunks = {}
    for _, hunk in ipairs(patch.hunks) do
      hunks[#hunks + 1] = { hunk.old_row, hunk.old_size, hunk.new_row, hunk.new_size }
    end
    return hunks
  end

  local function history(patches, revs)
    local state = {
      single_file = true,
      path_args = {},
      layout_opt = { default_layout = Diff2Hor },
      prepared_log_opts = {},
    }
    local ok, entry = adapter:parse_fh_line_trace_data({
      diff = patches,
      left_hash = revs[2],
      right_hash = revs[1],
    }, { hash = revs[1], diff = patches }, state)
    eq(true, ok)
    return entry, state
  end

  local function load(file)
    for _, side in ipairs(file.layout:files()) do
      await(side:create_buffer())
      eq(true, side:is_ready())
    end
  end

  local function collect_history()
    return adapter
      :file_history({
        log_opt = {
          single_file = {
            L = { '2,2:tracked.txt' },
            path_args = {},
            follow = false,
            max_count = 1,
          },
          multi_file = {},
        },
        layout_opt = { default_layout = Diff2Hor },
      })
      :collect()
  end

  before_each(function()
    root, buffers_before = vim.fn.tempname(), {}
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      buffers_before[bufnr] = true
    end
    vim.fn.mkdir(root .. '/hooks', 'p')
    git('init', '-q')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    git('config', 'core.hooksPath', root .. '/hooks')
    git('checkout', '-qb', 'ours')

    write('tracked.txt', { 'before', 'one', 'stable', 'two', 'after', 'tail' })
    write('old name.txt', { 'before', 'renamed', 'after' })
    commit('root')
    initial = git('rev-parse', 'HEAD')[1]
    write('tracked.txt', edited)
    commit('edit')
    git('mv', 'old name.txt', 'new name.txt')
    write('new name.txt', { 'before', 'RENAMED', 'after' })
    commit('rename')

    local err
    err, adapter = vcs.get_adapter({ top_indicators = { root } })
    eq(nil, err)
  end)

  after_each(function()
    if parse_stub then
      parse_stub:revert()
      parse_stub = nil
    end
    await(async.scheduler())
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if not buffers_before[bufnr] and bufnr ~= File.NULL_FILE.bufnr then
        api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(root, 'rf')
  end)

  it(
    'parses only patch data when commit metadata resembles diff headers',
    async_test(function()
      git('config', 'user.name', 'diff --cc misleading.txt')
      write('tracked.txt', { 'before', 'metadata test', 'stable', 'TWO', 'after', 'tail' })
      commit('@@@ misleading subject')
      local items = collect_history()
      eq(2, #items)
      eq(JobStatus.PROGRESS, items[1][1])
      eq('tracked.txt', items[1][2].files[1].path)
      eq(JobStatus.SUCCESS, items[2][1])
    end)
  )

  it(
    'reports a parser failure with the commit and ends history without success',
    async_test(function()
      local commit_hash = git('rev-parse', 'HEAD~1')[1]
      local parse = line_history.parse
      parse_stub = stub(line_history, 'parse', function(lines)
        lines[#lines + 1] = 'diff --cc tracked.txt'
        return parse(lines)
      end)

      local items = collect_history()
      eq(1, #items)
      eq(JobStatus.ERROR, items[1][1])
      eq(true, items[1][3]:find(commit_hash, 1, true) ~= nil)
      eq(true, items[1][3]:find('expected a two-way diff', 1, true) ~= nil)
    end)
  )

  it(
    'keeps disjoint traced ranges visible and folds the surrounding lines',
    async_test(function()
      local patches, revs = trace('-L2,2:tracked.txt', '-L4,4:tracked.txt')
      eq(1, #patches)
      eq('tracked.txt', patches[1].path_old)
      eq('tracked.txt', patches[1].path_new)
      eq({ { 2, 1, 2, 1 }, { 4, 1, 4, 1 } }, coordinates(patches[1]))

      local log = history(patches, revs)
      local file = log.files[1]
      eq(patches[1], log:get_diff(file.path))
      load(file)
      file:update_patch_folds(patches[1])
      local folds = { type = 'diff_patch', { 1, 1 }, { 3, 3 }, { 5, 6 } }
      eq(folds, file.layout.a.file.custom_folds)
      eq(folds, file.layout.b.file.custom_folds)
    end)
  )

  it(
    'represents a root commit with no old path and an empty-tree revision',
    async_test(function()
      local patches, revs = trace('-L2,2:tracked.txt', initial)
      eq(1, #patches)
      eq(nil, patches[1].path_old)
      eq('tracked.txt', patches[1].path_new)
      eq({ { 0, 0, 2, 1 } }, coordinates(patches[1]))
      local log = history(patches, revs)
      eq('tracked.txt', log.files[1].path)
      eq(GitRev.NULL_TREE_SHA, log.files[1].layout.a.file.rev.commit)
      eq(initial, log.files[1].layout.b.file.rev.commit)
    end)
  )

  it(
    'follows a renamed path containing spaces and loads both historical versions',
    async_test(function()
      local patches, revs = trace('-L2,2:new name.txt')
      eq(1, #patches)
      eq('old name.txt', patches[1].path_old)
      eq('new name.txt', patches[1].path_new)
      eq({ { 2, 1, 2, 1 } }, coordinates(patches[1]))
      local log, state = history(patches, revs)
      local file = log.files[1]
      eq('old name.txt', state.old_path)
      eq('old name.txt', file.oldpath)
      eq('new name.txt', file.path)
      load(file)
      eq(
        { 'before', 'renamed', 'after' },
        api.nvim_buf_get_lines(file.layout.a.file.bufnr, 0, -1, false)
      )
      eq(
        { 'before', 'RENAMED', 'after' },
        api.nvim_buf_get_lines(file.layout.b.file.bufnr, 0, -1, false)
      )
    end)
  )

  it(
    'keeps file boundaries and ignores path-like text inside hunks',
    async_test(function()
      write('tracked.txt', { 'before', '-- a/pretend-old.txt', 'stable', 'TWO', 'after', 'tail' })
      commit('patch-like content')
      write('tracked.txt', { 'before', '++ b/pretend-new.txt', 'stable', 'TWO', 'after', 'tail' })
      write('new name.txt', { 'before', 'also changed', 'after' })
      commit('change both files')
      local patches = trace('-L2,2:tracked.txt', '-L2,2:new name.txt')
      eq(2, #patches)
      local paths = {}
      for _, patch in ipairs(patches) do
        paths[#paths + 1] = patch.path_new
        eq(patch.path_old, patch.path_new)
        eq({ { 2, 1, 2, 1 } }, coordinates(patch))
      end
      table.sort(paths)
      eq({ 'new name.txt', 'tracked.txt' }, paths)
    end)
  )

  local changes = {
    {
      name = 'a newly inserted line with a zero-length old range',
      contents = { 'before', 'inserted', 'ONE', 'stable', 'TWO', 'after', 'tail' },
      range = '-L2,2:tracked.txt',
      hunk = { 2, 0, 2, 1 },
    },
    {
      name = 'a traced range containing a deletion',
      contents = { 'before', 'ONE', 'TWO', 'after', 'tail' },
      range = '-L1,5:tracked.txt',
      hunk = { 1, 6, 1, 5 },
    },
    {
      name = 'a changed last line without a final newline',
      contents = { 'before', 'ONE', 'stable', 'TWO', 'after', 'unterminated' },
      range = '-L6,6:tracked.txt',
      hunk = { 6, 1, 6, 1 },
      no_eol = true,
    },
  }

  for _, change in ipairs(changes) do
    it(
      'parses ' .. change.name,
      async_test(function()
        write('tracked.txt', change.contents, change.no_eol)
        commit('change')
        local patches = trace(change.range)
        eq(1, #patches)
        eq('tracked.txt', patches[1].path_old)
        eq('tracked.txt', patches[1].path_new)
        eq({ change.hunk }, coordinates(patches[1]))
      end)
    )
  end

  it(
    'parses the two-way patches Git emits while tracing through a merge',
    async_test(function()
      git('checkout', '-qb', 'theirs')
      write('tracked.txt', { 'before', 'theirs', 'stable', 'TWO', 'after', 'tail' })
      commit('theirs')
      git('checkout', '-q', 'ours')
      write('tracked.txt', { 'before', 'ours', 'stable', 'TWO', 'after', 'tail' })
      commit('ours')
      eq(1, run_git('merge', '--no-edit', 'theirs').code)
      write('tracked.txt', { 'before', 'resolved', 'stable', 'TWO', 'after', 'tail' })
      commit('resolve merge')

      for _, mode in ipairs({ 'combined', 'dense-combined' }) do
        local lines = git(
          'log',
          '--color=never',
          '--no-ext-diff',
          '--format=',
          '-L2,2:tracked.txt',
          '--diff-merges=' .. mode
        )
        local patches, err = line_history.parse(lines)
        eq(nil, err)
        local headers = 0
        for _, line in ipairs(lines) do
          if line:match('^diff ') then
            eq('diff --git a/tracked.txt b/tracked.txt', line)
            headers = headers + 1
          end
        end
        eq(true, headers > 0)
        eq(headers, #patches)
        for _, patch in ipairs(patches) do
          eq('tracked.txt', patch.path_new)
          if patch.path_old then
            eq('tracked.txt', patch.path_old)
            eq({ { 2, 1, 2, 1 } }, coordinates(patch))
          else
            eq({ { 0, 0, 2, 1 } }, coordinates(patch))
          end
        end
      end
    end)
  )
end)

describe('Git line-history patch validation', function()
  local patch = {
    'diff --git a/file.txt b/file.txt',
    '--- a/file.txt',
    '+++ b/file.txt',
    '@@ -1,1 +1,1 @@',
    '-old',
    '+new',
  }

  it('accepts commits without patches', function()
    local files, err = line_history.parse({ '', '' })
    eq(nil, err)
    eq({}, files)
  end)

  it(
    'rejects unsupported formats and incomplete patches without returning partial files',
    function()
      local cases = {
        { lines = { 'diff --cc file.txt' }, error = 'expected a two-way diff' },
        { lines = { 'diff --combined file.txt' }, error = 'expected a two-way diff' },
        { replace = { 4, '@@@ -1,1 -1,1 +1,1 @@@' }, error = 'hunk header' },
        { replace = { 4, '@@ -invalid +1,1 @@' }, error = 'hunk header' },
        { replace = { 4, '@@ -0,1 +1,1 @@' }, error = 'invalid hunk coordinates' },
        { replace = { 4, '@@ -1,1 +0,1 @@' }, error = 'invalid hunk coordinates' },
        { replace = { 4, '@@ -1,0 +1,0 @@' }, error = 'invalid hunk coordinates' },
        { replace = { 2, '--- /dev/null' }, error = 'invalid hunk coordinates' },
        { replace = { 2, '--- wrong-prefix/file.txt' }, error = 'old path header' },
        { replace = { 3, '+++ /dev/null' }, error = 'new path header' },
        { lines = { patch[1] }, error = 'missing old path header' },
        { lines = { patch[1], patch[2] }, error = 'missing new path header' },
        { lines = { patch[1], patch[2], patch[3] }, error = 'missing hunk header' },
        { lines = vim.list_slice(patch, 1, 5), error = 'truncated hunk body' },
        { replace = { 5, 'unexpected body line' }, error = 'invalid hunk body' },
        { replace = { 6, '-extra old line' }, error = 'exceeds its declared line counts' },
        { lines = { patch[1], 'Binary files a/file.txt and b/file.txt differ' }, error = 'binary' },
        { lines = { patch[1], 'GIT binary patch' }, error = 'binary' },
        { lines = { patch[4], patch[5], patch[6] }, error = 'expected a two-way file' },
      }

      for _, case in ipairs(cases) do
        local lines = vim.deepcopy(case.lines or patch)
        if case.replace then lines[case.replace[1]] = case.replace[2] end
        -- A valid earlier file must not escape as a partially parsed result.
        local prefix = vim.deepcopy(patch)
        prefix[#prefix + 1] = ''
        lines = vim.list_extend(prefix, lines)
        local files, err = line_history.parse(lines)
        eq(nil, files)
        eq(true, err ~= nil and err:find(case.error, 1, true) ~= nil)
      end
    end
  )
end)
