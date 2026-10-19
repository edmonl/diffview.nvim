local helpers = require('diffview.tests.helpers')
local renderer = require('diffview.renderer')

local eq = helpers.eq
local api = vim.api

describe('diffview.renderer', function()
  local bufnr, data

  before_each(function()
    bufnr = api.nvim_create_buf(false, true)
    vim.bo[bufnr].modifiable = false
    data = renderer.RenderData('diffview-renderer-tests')
  end)

  after_each(function()
    api.nvim_buf_delete(bufnr, { force = true })
    data:destroy()
  end)

  local function highlights(namespace)
    local result = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
      local detail = mark[4]
      result[#result + 1] = {
        mark[2],
        mark[3],
        detail.end_row,
        detail.end_col,
        detail.hl_group,
      }
    end
    return result
  end

  for _, nested in ipairs({ false, true }) do
    it(
      ('renders byte ranges in %s data'):format(nested and 'nested component' or 'flat'),
      function()
        local root, offset = data, 0
        local lines = { 'aé界z', 'tail', '' }
        if nested then
          local parts = data:create_component({
            { name = 'heading' },
            { name = 'body', { name = 'lead' }, { name = 'content' } },
          })
          parts.heading.comp:add_line('heading')
          parts.body.lead.comp:add_line()
          root, offset = parts.body.content.comp, 2
        end
        root.lines = lines
        root:add_hl('ErrorMsg', 0, 1, 6)
        root:add_hl('WarningMsg', 0, 6, 6)
        root:add_hl('MoreMsg', 1, 1, -1)
        root:add_hl('Question', 1, 0, 100)
        root:add_hl('Title', 2, 0, -1)
        root:add_hl('Search', 99, 0, -1)
        renderer.render(bufnr, data)

        eq({
          { offset, 1, offset, 6, 'ErrorMsg' },
          { offset, 6, offset, 6, 'WarningMsg' },
          { offset + 1, 0, offset + 1, 4, 'Question' },
          { offset + 1, 1, offset + 2, 0, 'MoreMsg' },
          { offset + 2, 0, offset + 3, 0, 'Title' },
        }, highlights(data.namespace))
        eq(
          nested and { 'heading', '', 'aé界z', 'tail', '' } or lines,
          api.nvim_buf_get_lines(bufnr, 0, -1, false)
        )
        eq(false, vim.bo[bufnr].modifiable)
      end
    )
  end

  it('replaces its highlights on redraw without clearing other namespaces', function()
    local other = api.nvim_create_namespace('diffview-renderer-other')
    data.lines = { 'first line', 'second line' }
    data:add_hl('Title', 0, 0, -1)
    data:add_hl('ErrorMsg', 1, 0, 3)
    renderer.render(bufnr, data)
    api.nvim_buf_set_extmark(bufnr, other, 0, 0, { end_col = 3, hl_group = 'Search' })
    eq(2, #highlights(data.namespace))

    data:clear()
    data.lines = { 'new' }
    data:add_hl('WarningMsg', 0, 0, 3)
    renderer.render(bufnr, data)
    eq({ { 0, 0, 0, 3, 'WarningMsg' } }, highlights(data.namespace))
    eq(1, #highlights(other))

    data:clear()
    renderer.render(bufnr, data)
    eq({}, highlights(data.namespace))
    eq(1, #highlights(other))
    eq({ '' }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
    eq(false, vim.bo[bufnr].modifiable)
  end)
end)
