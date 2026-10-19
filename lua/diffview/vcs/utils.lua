local FileDict = require('diffview.vcs.file_dict').FileDict
local RevType = require('diffview.vcs.rev').RevType
local Semaphore = require('diffview.control').Semaphore
local async = require('diffview.async')
local oop = require('diffview.oop')
local utils = require('diffview.utils')

local api = vim.api
local await = async.await
local fmt = string.format
local logger = DiffviewGlobal.logger

local M = {}

---@enum JobStatus
local JobStatus = oop.enum({
  SUCCESS = 1,
  PROGRESS = 2,
  ERROR = 3,
  KILLED = 4,
  FATAL = 5,
})

---@type diffview.Job[]
local sync_jobs = {}
local job_queue_sem = Semaphore(1)

---@param job diffview.Job
M.resume_sync_queue = async.void(function(job)
  local permit = await(job_queue_sem:acquire()) --[[@as Permit ]]
  local idx = utils.vec_indexof(sync_jobs, job)
  if idx > -1 then table.remove(sync_jobs, idx) end
  permit:forget()

  if sync_jobs[1] and not sync_jobs[1]:is_started() then sync_jobs[1]:start() end
end)

---@param job diffview.Job
M.queue_sync_job = async.void(function(job)
  job:on_exit(function() M.resume_sync_queue(job) end)

  local permit = await(job_queue_sem:acquire()) --[[@as Permit ]]
  table.insert(sync_jobs, job)

  if #sync_jobs == 1 then job:start() end

  permit:forget()
end)

---Get a list of files modified between two revs.
---@param adapter VCSAdapter
---@param left Rev
---@param right Rev
---@param path_args string[]|nil
---@param dv_opt DiffViewOptions
---@param opt vcs.adapter.LayoutOpt
---@param callback function
---@return string[]? err
---@return FileDict?
M.diff_file_list = async.wrap(function(adapter, left, right, path_args, dv_opt, opt, callback)
  ---@type FileDict
  local files = FileDict()
  local rev_args = adapter:rev_to_args(left, right)
  local errors = {}
  (function()
    local err, tfiles, tconflicts = await(
      adapter:tracked_files(left, right, utils.vec_join(rev_args, '--', path_args), 'working', opt)
    )

    if err then
      errors[#errors + 1] = err
      utils.err('Failed to get git status for tracked files!', true)
      return
    end

    files:set_working(tfiles)
    files:set_conflicting(tconflicts)

    if
      not adapter:show_untracked({
        dv_opt = dv_opt,
        revs = { left = left, right = right },
      })
    then
      return
    end

    ---@diagnostic disable-next-line: redefined-local
    local err, ufiles = await(adapter:untracked_files(left, right, opt))

    if err then
      errors[#errors + 1] = err
      utils.err('Failed to get git status for untracked files!', true)
    else
      files:set_working(utils.vec_join(files.working, ufiles))

      utils.merge_sort(files.working, function(a, b) return a.path:lower() < b.path:lower() end)
    end
  end)()

  if left.type == RevType.STAGE and right.type == RevType.LOCAL then
    local left_rev = adapter:head_rev() or adapter.Rev.new_null_tree()
    local right_rev = adapter.Rev(RevType.STAGE, 0)
    ---@diagnostic disable-next-line: redefined-local
    local err, tfiles = await(
      adapter:tracked_files(
        left_rev,
        right_rev,
        utils.vec_join('--cached', left_rev.commit, '--', path_args),
        'staged',
        opt
      )
    )

    if err then
      errors[#errors + 1] = err
      utils.err('Failed to get git status for staged files!', true)
    else
      files:set_staged(tfiles)
    end
  end

  if #errors > 0 then
    callback(utils.vec_join(unpack(errors)), nil)
    return
  end

  files:update_file_trees()
  callback(nil, files)
end, 7)

---Restore a file to the state it was in, in a given commit / rev. If no commit
---is given, unstaged files are restored to the state in index, and staged files
---are restored to the state in HEAD. The file will also be written into the
---object database such that the action can be undone.
---@param adapter VCSAdapter
---@param path string
---@param kind vcs.FileKind
---@param commit? string
M.restore_file = async.void(function(adapter, path, kind, commit)
  local ok, undo = await(adapter:file_restore(path, kind, commit))

  if not ok then
    utils.err("Failed to revert file! See ':DiffviewLog' for details.", true)
    return
  end

  local rev_name = (commit and commit:sub(1, 11)) or (kind == 'staged' and 'HEAD' or 'index')
  local msg = fmt('File restored from %s. %s', rev_name, undo and ('Undo with ' .. undo) or '')

  logger:info(msg)
  utils.info(msg, true)
end)

local CONFLICT_START = [[^<<<<<<< ]]
local CONFLICT_BASE = [[^||||||| ]]
local CONFLICT_SEP = [[^=======$]]
local CONFLICT_END = [[^>>>>>>> ]]

---@class ConflictRegion
---@field first integer
---@field last integer
---@field ours { first: integer, last: integer, content?: string[] }
---@field base { first: integer, last: integer, content?: string[] }
---@field theirs { first: integer, last: integer, content?: string[] }

---@param lines string[]
---@param winid? integer
---@return ConflictRegion[] conflicts
---@return ConflictRegion? cur_conflict The conflict under the cursor in the given window.
---@return integer cur_conflict_idx Index of the current conflict. Will be 0 if the cursor is before the first conflict, and `#conflicts + 1` if the cursor is after the last conflict.
function M.parse_conflicts(lines, winid)
  local ret = {}
  local has_start, has_base, has_sep = false, false, false
  local cur, cursor, cur_conflict, cur_idx

  if winid and api.nvim_win_is_valid(winid) then cursor = api.nvim_win_get_cursor(winid) end

  local function handle(data)
    local first = math.min(
      data.ours.first or math.huge,
      data.base.first or math.huge,
      data.theirs.first or math.huge
    )

    if first == math.huge then return end

    local last = math.max(data.ours.last or -1, data.base.last or -1, data.theirs.last or -1)

    if last == -1 then return end

    if data.ours.first and data.ours.last and data.ours.first < data.ours.last then
      data.ours.content = utils.vec_slice(lines, data.ours.first + 1, data.ours.last)
    end

    if data.base.first and data.base.last and data.base.first < data.base.last then
      data.base.content = utils.vec_slice(lines, data.base.first + 1, data.base.last)
    end

    if data.theirs.first and data.theirs.last and data.theirs.first < data.theirs.last - 1 then
      data.theirs.content = utils.vec_slice(lines, data.theirs.first + 1, data.theirs.last - 1)
    end

    if cursor then
      if not cur_conflict and cursor[1] >= first and cursor[1] <= last then
        cur_conflict = data
        cur_idx = #ret + 1
      elseif cursor[1] > last then
        cur_idx = (cur_idx or 0) + 1
      end
    end

    data.first = first
    data.last = last
    ret[#ret + 1] = data
  end

  local function new_cur()
    return {
      ours = {},
      base = {},
      theirs = {},
    }
  end

  cur = new_cur()

  for i, line in ipairs(lines) do
    if line:match(CONFLICT_START) then
      if has_start then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_start = true
      cur.ours.first = i
      cur.ours.last = i
    elseif line:match(CONFLICT_BASE) then
      if has_base then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_base = true
      cur.base.first = i
      cur.ours.last = i - 1
    elseif line:match(CONFLICT_SEP) then
      if has_sep then
        handle(cur)
        cur, has_start, has_base, has_sep = new_cur(), false, false, false
      end

      has_sep = true
      cur.theirs.first = i
      cur.theirs.last = i

      if has_base then
        cur.base.last = i - 1
      else
        cur.ours.last = i - 1
      end
    elseif line:match(CONFLICT_END) then
      if not has_sep then
        if has_base then
          cur.base.last = i - 1
        elseif has_start then
          cur.ours.last = i - 1
        end
      end

      cur.theirs.first = cur.theirs.first or i
      cur.theirs.last = i
      handle(cur)
      cur, has_start, has_base, has_sep = new_cur(), false, false, false
    end
  end

  handle(cur)

  if cursor and cur_idx then
    if cursor[1] > ret[#ret].last then cur_idx = #ret + 1 end
  end

  return ret, cur_conflict, cur_idx or 0
end

---@param version { major: integer, minor: integer, patch: integer }
---@param required { major: integer, minor: integer, patch: integer }
---@return boolean
function M.check_semver(version, required)
  if version.major ~= required.major then
    return version.major > required.major
  elseif version.minor ~= required.minor then
    return version.minor > required.minor
  elseif version.patch ~= required.patch then
    return version.patch > required.patch
  end
  return true
end

M.JobStatus = JobStatus
return M
