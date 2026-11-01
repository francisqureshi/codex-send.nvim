local M = {}

function M.search_text(item)
  if item.manual then
    return 'Enter session name or UUID…'
  end
  return string.format('%s  ·  %s', item.cwd or '(cwd unavailable)', item.thread_name or '(untitled)')
end

-- Drop leading breadcrumbs, preserving the project end of the path.
function M.path_label(path, limit)
  local label = path and vim.fn.fnamemodify(path, ':~') or '(cwd unavailable)'
  if vim.fn.strdisplaywidth(label) <= limit then
    return label
  end
  local parts = vim.split(label, '/', { trimempty = true })
  while #parts > 1 do
    table.remove(parts, 1)
    label = '…/' .. table.concat(parts, '/')
    if vim.fn.strdisplaywidth(label) <= limit then
      return label
    end
  end
  local tail = parts[1] or label
  while vim.fn.strchars(tail) > 0 and vim.fn.strdisplaywidth('…' .. tail) > limit do
    tail = vim.fn.strcharpart(tail, 1)
  end
  return '…' .. tail
end

function M.show(items, callback)
  -- Only adapt Telescope when it is already the user's vim.ui.select provider.
  -- Other providers keep full labels, so their built-in search retains full paths.
  local source = debug.getinfo(vim.ui.select, 'S').source
  if not source:find('telescope/_extensions/ui-select.lua', 1, true) then
    vim.ui.select(items, {
      prompt = 'Codex sessions · grouped by directory · search name or cwd:',
      format_item = M.search_text,
    }, callback)
    return
  end

  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local picker
  local settled = false
  local function finish(item)
    if settled then
      return
    end
    settled = true
    vim.schedule(function()
      callback(item)
    end)
  end
  picker = require('telescope.pickers').new(require('telescope.themes').get_dropdown { previewer = false }, {
    prompt_title = 'Codex sessions · name or cwd',
    finder = require('telescope.finders').new_table {
      results = items,
      entry_maker = function(item)
        return {
          value = item,
          ordinal = M.search_text(item), -- Always search the full, unabridged cwd.
          display = function()
            if item.manual then
              return M.search_text(item)
            end
            local available = math.max(1, vim.o.columns - 4)
            if picker and picker.results_win and vim.api.nvim_win_is_valid(picker.results_win) then
              available = math.max(1, vim.api.nvim_win_get_width(picker.results_win) - 4)
            end
            local cap = math.max(1, math.floor(math.min(vim.o.columns, available) * 0.4))
            local path = M.path_label(item.cwd, cap)
            local padding = string.rep(' ', math.max(0, cap - vim.fn.strdisplaywidth(path)))
            local prefix = path .. padding .. '  ·  '
            return prefix .. (item.thread_name or '(untitled)'), { { { 0, #path }, 'Comment' } }
          end,
        }
      end,
    },
    sorter = require('telescope.config').values.generic_sorter {},
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        -- Closing also calls on-cancel, so settle the selection first.
        if settled then
          return
        end
        settled = true
        actions.close(prompt_bufnr)
        vim.schedule(function()
          callback(selected and selected.value)
        end)
      end)
      actions.close:enhance {
        post = function()
          finish(nil)
        end,
      }
      return true
    end,
  })
  picker:find()
end

return M
