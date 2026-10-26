local diffview = require('diffview')
local lib = require('diffview.lib')
local View = require('diffview.scene.view').View
local eq = require('diffview.tests.helpers').eq

local api = vim.api

describe('view tab navigation', function()
  local first_tab, second_tab, view, tabclose

  local function open_view()
    view = View()
    view.init_layout = function() end
    view.post_open = function() end
    lib.add_view(view)
    view:open()
  end

  before_each(function()
    tabclose = vim.o.tabclose
    vim.o.tabclose = ''
    first_tab = api.nvim_get_current_tabpage()
    vim.cmd('tabnew')
    second_tab = api.nvim_get_current_tabpage()
    api.nvim_set_current_tabpage(first_tab)
  end)

  after_each(function()
    if view then
      if api.nvim_tabpage_is_valid(view.tabpage) then view:close() end
      lib.dispose_view(view)
      view = nil
    end
    vim.cmd('tabonly!')
    vim.o.tabclose = tabclose
  end)

  it('returns to the previous tab instead of the tab to the right', function()
    open_view()

    diffview.close()

    eq(first_tab, api.nvim_get_current_tabpage())
    eq({ first_tab, second_tab }, api.nvim_list_tabpages())
    eq('', vim.o.tabclose)
  end)

  it('returns to the last accessed tab after revisiting the view', function()
    open_view()
    api.nvim_set_current_tabpage(second_tab)
    api.nvim_set_current_tabpage(view.tabpage)
    vim.cmd('tabmove 0')

    diffview.close()

    eq(second_tab, api.nvim_get_current_tabpage())
  end)

  it('keeps focus when closing a view in another tab', function()
    open_view()
    api.nvim_set_current_tabpage(second_tab)

    view:close()

    eq(second_tab, api.nvim_get_current_tabpage())
    eq({ first_tab, second_tab }, api.nvim_list_tabpages())
  end)

  it('closes normally when the previous tab no longer exists', function()
    open_view()
    vim.cmd('tabclose ' .. api.nvim_tabpage_get_number(first_tab))

    diffview.close()

    eq(second_tab, api.nvim_get_current_tabpage())
    eq({ second_tab }, api.nvim_list_tabpages())
  end)

  it('creates a replacement when closing the only remaining tab', function()
    open_view()
    vim.cmd('tabonly')

    diffview.close()

    eq(false, api.nvim_tabpage_is_valid(view.tabpage))
    eq(1, #api.nvim_list_tabpages())
  end)
end)
