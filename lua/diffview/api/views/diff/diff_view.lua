local async = require('diffview.async')
local lazy = require('diffview.lazy')

local DiffView = lazy.access('diffview.scene.views.diff.diff_view', 'DiffView') ---@type DiffView|LazyModule
local FileEntry = lazy.access('diffview.scene.file_entry', 'FileEntry') ---@type FileEntry|LazyModule
local FilePanel = lazy.access('diffview.scene.views.diff.file_panel', 'FilePanel') ---@type FilePanel|LazyModule
local Rev = lazy.access('diffview.vcs.adapters.git.rev', 'GitRev') ---@type GitRev|LazyModule
local RevType = lazy.access('diffview.vcs.rev', 'RevType') ---@type RevType|LazyModule
local vcs_utils = lazy.require('diffview.vcs') ---@module "diffview.vcs"
local oop = lazy.require('diffview.oop') ---@module "diffview.oop"
local utils = lazy.require('diffview.utils') ---@module "diffview.utils"

local await = async.await
local logger = DiffviewGlobal.logger

local M = {}

---@class FileData
---@field path string Path relative to git root.
---@field oldpath string|nil If the file has been renamed, this should be the old path, oterhwise nil.
---@field status string Git status symbol.
---@field stats GitStats|nil
---@field left_null boolean|nil Override whether the left buffer is empty; nil infers from Git status.
---@field right_null boolean|nil Override whether the right buffer is empty; nil infers from Git status.
---@field selected boolean|nil Indicates that this should be the initially selected file.

---@class CDiffView : DiffView
---@field files any
---@field fetch_files function A function that should return an updated list of files.
---@field get_file_data function A function that is called with parameters `path: string` and `split: string`, and should return a list of lines that should make up the buffer.
local CDiffView = oop.create_class('CDiffView', DiffView.__get())

---CDiffView constructor.
---@param opt any
function CDiffView:init(opt)
  logger:info('[api] Creating a new Custom DiffView.')
  self.valid = false

  local err, adapter = vcs_utils.get_adapter({ top_indicators = { opt.git_root } })

  if err then
    utils.err(
      ('Failed to create an adapter for the repository: %s'):format(utils.str_quote(opt.git_root))
    )
    return
  end

  ---@cast adapter -?

  -- Fix malformed revs
  for _, v in ipairs({ 'left', 'right' }) do
    local rev = opt[v]
    if not rev or not rev.type then opt[v] = Rev(RevType.STAGE, 0) end
  end

  self.fetch_files = opt.update_files
  self.get_file_data = opt.get_file_data

  self:super(vim.tbl_extend('force', opt, {
    adapter = adapter,
    panel = FilePanel(
      adapter,
      self.files,
      self.path_args,
      self.rev_arg or adapter:rev_to_pretty_string(opt.left, opt.right)
    ),
  }))

  if type(opt.files) == 'table' and not vim.tbl_isempty(opt.files) then
    local files, err = self:create_file_entries(opt.files)
    if err then
      utils.err(err, true)
      return
    end

    for kind, entries in pairs(files) do
      for _, entry in ipairs(entries) do
        table.insert(self.files[kind], entry)
      end
    end
    self.files:update_file_trees()

    if self.panel.cur_file then
      vim.schedule(function() self:set_file(self.panel.cur_file, false, true) end)
    end
  end

  self.valid = true
end

---@override
CDiffView.get_updated_files = async.wrap(function(self, callback)
  local err

  repeat
    local ok, new_files = pcall(self.fetch_files, self)

    if not ok or type(new_files) ~= 'table' then
      err = { 'Integrating plugin failed to provide file data!' }
      break
    end

    await(async.scheduler())
    ---@diagnostic disable-next-line: redefined-local
    local ok, entries, entry_err = pcall(self.create_file_entries, self, new_files)

    if not ok then
      err = { 'Integrating plugin provided malformed file data!' }
      break
    end

    if entry_err then
      err = entry_err
      break
    end

    callback(nil, entries)
    return
  until true

  utils.err(err, true)
  logger:error(table.concat(err, '\n'))
  callback(err, nil)
end)

---Create entries using Git's available stages for conflict panes.
---@param files table
---@return table? entries
---@return string[]? err
function CDiffView:create_file_entries(files)
  local entries = {}
  local merge_stages
  if files.conflicting and #files.conflicting > 0 then
    local err
    err, merge_stages = self.adapter:get_unmerged_stages()
    if err then return nil, err end
  end

  local sections = {
    {
      kind = 'conflicting',
      -- Git's index may have been resolved since the provider captured its list.
      files = vim.tbl_filter(
        function(file) return merge_stages[file.path] ~= nil end,
        files.conflicting or {}
      ),
    },
    { kind = 'working', files = files.working or {}, left = self.left, right = self.right },
    {
      kind = 'staged',
      files = files.staged or {},
      left = self.adapter:head_rev(),
      right = Rev(RevType.STAGE, 0),
    },
  }

  for _, v in ipairs(sections) do
    entries[v.kind] = {}

    for _, file_data in ipairs(v.files) do
      if v.kind == 'conflicting' then
        table.insert(
          entries[v.kind],
          FileEntry.with_layout(CDiffView.get_default_merge_layout(), {
            adapter = self.adapter,
            path = file_data.path,
            oldpath = file_data.oldpath,
            status = 'U',
            kind = 'conflicting',
            merge_stages = merge_stages[file_data.path],
            revs = {
              a = Rev(RevType.STAGE, 2),
              b = Rev(RevType.LOCAL),
              c = Rev(RevType.STAGE, 3),
              d = Rev(RevType.STAGE, 1),
            },
          })
        )
      else
        table.insert(
          entries[v.kind],
          FileEntry.with_layout(CDiffView.get_default_layout(), {
            adapter = self.adapter,
            path = file_data.path,
            oldpath = file_data.oldpath,
            status = file_data.status,
            stats = file_data.stats,
            kind = v.kind,
            revs = {
              a = v.left,
              b = v.right,
            },
            get_data = self.get_file_data,
            null_overrides = { a = file_data.left_null, b = file_data.right_null },
          })
        )
      end

      if file_data.selected then self.panel:set_cur_file(entries[v.kind][#entries[v.kind]]) end
    end
  end

  return entries
end

M.CDiffView = CDiffView
return M
