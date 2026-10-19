local M = {}

local DIFF_HEADER = [[^diff %-%-git ]]
local HUNK_HEADER = [[^@@+ %-(%d+),(%d+) %+(%d+),(%d+) @@+]]

---@class git.LineHistoryHunk
---@field old_row integer
---@field old_size integer
---@field new_row integer
---@field new_size integer

---@class git.LineHistoryFile
---@field path_old? string
---@field path_new? string
---@field hunks git.LineHistoryHunk[]

---Parse the two-way patches emitted by `git log -L`. History and folding only
---consume paths and hunk coordinates; patch bodies and metadata are ignored.
---@param lines string[]
---@return git.LineHistoryFile[]
function M.parse(lines)
  local files = {}
  local current, in_hunks

  for _, line in ipairs(lines) do
    if line:match(DIFF_HEADER) then
      current = { hunks = {} }
      files[#files + 1] = current
      in_hunks = false
    elseif current then
      local old_row, old_size, new_row, new_size = line:match(HUNK_HEADER)
      if old_row then
        current.hunks[#current.hunks + 1] = {
          old_row = tonumber(old_row),
          old_size = tonumber(old_size),
          new_row = tonumber(new_row),
          new_size = tonumber(new_size),
        }
        in_hunks = true
      elseif not in_hunks then
        if line:match('^%-%-%- ') then
          current.path_old = line:match('^%-%-%- a/(.*)')
        elseif line:match('^%+%+%+ ') then
          current.path_new = line:match('^%+%+%+ b/(.*)')
        end
      end
    end
  end

  return files
end

return M
