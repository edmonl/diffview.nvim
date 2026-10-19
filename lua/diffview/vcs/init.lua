local GitAdapter = require('diffview.vcs.adapters.git').GitAdapter

local M = {}

---@class vcs.init.get_adapter.Opt
---@field top_indicators string[]?
---@field cmd_ctx vcs.init.get_adapter.Opt.Cmd_Ctx? # Context data from a command call.

---@class vcs.init.get_adapter.Opt.Cmd_Ctx
---@field path_args string[] # Raw path args
---@field cpath string? # Cwd path given by the `-C` flag option

---@param opt vcs.init.get_adapter.Opt
---@return string? err
---@return VCSAdapter? adapter
function M.get_adapter(opt)
  if not opt.cmd_ctx then opt.cmd_ctx = {} end

  if not GitAdapter.bootstrap.done then GitAdapter.run_bootstrap() end
  if GitAdapter.bootstrap.ok then
    local path_args
    local top_indicators = opt.top_indicators

    if not top_indicators then
      path_args, top_indicators =
        GitAdapter.get_repo_paths(opt.cmd_ctx.path_args, opt.cmd_ctx.cpath)
    end

    local err, toplevel = GitAdapter.find_toplevel(top_indicators)

    if not err then
      -- Create a new adapter instance. Store the resolved path args and the
      -- cpath in the adapter context.
      return GitAdapter.create(toplevel, path_args, opt.cmd_ctx.cpath)
    end
  end

  return 'Not a Git repo (or any parent), or Git is unavailable!'
end

return M
