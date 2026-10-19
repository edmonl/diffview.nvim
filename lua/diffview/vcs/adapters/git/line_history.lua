local M = {}

local DIFF_HEADER = [[^diff %-%-git a/.+ b/.+$]]
local HUNK_HEADER = [[^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@(.*)$]]
local NO_NEWLINE = [[\ No newline at end of file]]

---@class git.LineHistoryHunk
---@field old_row integer
---@field old_size integer
---@field new_row integer
---@field new_size integer

---@class git.LineHistoryFile
---@field path_old? string
---@field path_new string
---@field hunks git.LineHistoryHunk[]

---Parse the two-way patches emitted by `git log -L`, excluding commit metadata.
---Only paths and hunk coordinates are retained; bodies are counted to detect
---truncated patches. An empty patch list is valid for commits without changes.
---@param lines string[]
---@return git.LineHistoryFile[]? files # Nil on malformed or unsupported input.
---@return string? error
function M.parse(lines)
  local files = {}
  local current, phase
  local old_left, new_left = 0, 0

  local function incomplete()
    if not current then return end
    if phase == 'old_path' then return 'missing old path header' end
    if phase == 'new_path' then return 'missing new path header' end
    if #current.hunks == 0 then return 'missing hunk header' end
    if old_left ~= 0 or new_left ~= 0 then return 'truncated hunk body' end
  end

  local function fail(i, message)
    return nil, ('Invalid Git line-history patch at line %d: %s'):format(i, message)
  end

  for i, line in ipairs(lines) do
    if old_left > 0 or new_left > 0 then
      local prefix = line:sub(1, 1)
      if line == NO_NEWLINE then
        -- This marker does not consume a line on either side.
      elseif prefix == '-' then
        old_left = old_left - 1
      elseif prefix == '+' then
        new_left = new_left - 1
      elseif prefix == ' ' then
        old_left, new_left = old_left - 1, new_left - 1
      else
        return fail(i, 'truncated or invalid hunk body')
      end

      if old_left < 0 or new_left < 0 then
        return fail(i, 'hunk body exceeds its declared line counts')
      end
    elseif line:match('^diff ') then
      local err = incomplete()
      if err then return fail(i, err) end
      if not line:match(DIFF_HEADER) then
        return fail(i, 'unsupported diff header; expected a two-way diff --git patch')
      end
      current = { hunks = {} }
      files[#files + 1] = current
      phase = 'old_path'
    elseif line == '' then
      local err = incomplete()
      if err then return fail(i, err) end
      current, phase = nil, nil
    elseif line == 'GIT binary patch' or line:match('^Binary files ') then
      return fail(i, 'binary patches are not supported')
    elseif phase == 'old_path' then
      current.path_old = line:match('^%-%-%- a/(.+)$')
      if not current.path_old and line ~= '--- /dev/null' then
        return fail(i, 'expected an old path header (--- a/... or --- /dev/null)')
      end
      phase = 'new_path'
    elseif phase == 'new_path' then
      current.path_new = line:match('^%+%+%+ b/(.+)$')
      if not current.path_new then return fail(i, 'expected a new path header (+++ b/...)') end
      phase = 'hunks'
    elseif current and line:match('^@@') then
      local old_row, old_size, new_row, new_size, tail = line:match(HUNK_HEADER)
      if not old_row or (tail ~= '' and tail:sub(1, 1) ~= ' ') then
        return fail(i, 'unsupported or malformed hunk header; expected @@ -row,size +row,size @@')
      end
      old_row, old_size = tonumber(old_row), tonumber(old_size)
      new_row, new_size = tonumber(new_row), tonumber(new_size)
      if
        (old_size > 0 and old_row == 0)
        or (new_size > 0 and new_row == 0)
        or (old_size == 0 and new_size == 0)
        or (not current.path_old and (old_row ~= 0 or old_size ~= 0))
      then
        return fail(i, 'invalid hunk coordinates')
      end
      current.hunks[#current.hunks + 1] = {
        old_row = old_row,
        old_size = old_size,
        new_row = new_row,
        new_size = new_size,
      }
      old_left, new_left = old_size, new_size
    elseif line == NO_NEWLINE and current and #current.hunks > 0 then
      -- A marker may follow the final line of a hunk as well.
    else
      return fail(i, 'unexpected data; expected a two-way file or hunk header')
    end
  end

  local err = incomplete()
  if err then return fail(#lines + 1, err) end

  return files
end

return M
