local health = vim.health
local fmt = string.format

local M = {}

M.plugin_deps = {
  {
    name = 'nvim-web-devicons',
    optional = true,
  },
}

---@param cmd string|string[]
---@return string[] stdout
---@return integer code
local function system_list(cmd)
  local out = vim.fn.systemlist(cmd)
  return out or {}, vim.v.shell_error
end

local function lualib_available(name)
  local ok, _ = pcall(require, name)
  return ok
end

function M.check()
  if vim.fn.has('nvim-0.12') == 0 then health.error('Diffview.nvim requires Neovim 0.12.0+') end

  -- LuaJIT
  if not _G.jit then
    health.error(
      'Not running on LuaJIT! Non-JIT Lua runtimes are not officially supported by the plugin. Mileage may vary.'
    )
  end

  health.start('Checking plugin dependencies')

  local missing_essential = false

  for _, plugin in ipairs(M.plugin_deps) do
    if lualib_available(plugin.name) then
      health.ok(plugin.name .. ' installed.')
    else
      if plugin.optional then
        health.warn(fmt("Optional dependency '%s' not found.", plugin.name))
      else
        missing_essential = true
        health.error(fmt("Dependency '%s' not found!", plugin.name))
      end
    end
  end

  health.start('Checking VCS tools');
  (function()
    if missing_essential then
      health.warn(
        'Cannot perform checks on external dependencies without all essential plugin dependencies installed!'
      )
      return
    end

    health.info('The plugin requires Git.')

    local GitAdapter = require('diffview.vcs.adapters.git').GitAdapter
    local bs = GitAdapter.bootstrap
    if not bs.done then GitAdapter.run_bootstrap() end

    if bs.version_string then health.ok('Git found.') end

    if bs.ok then
      health.ok(fmt('Git is up-to-date. (%s)', bs.version_string))
    else
      health.warn(bs.err or 'Git: Unknown error')
      health.error('No valid Git executable was found!')
    end
  end)()
end

return M
