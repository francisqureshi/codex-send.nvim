-- Adapted from carderne/pi-nvim (MIT); see LICENSE.
local M = {}

--- Capture visual selection info before it's lost.
--- @return table|nil
function M.capture_selection()
  local start_pos = vim.fn.getpos "'<"
  local end_pos = vim.fn.getpos "'>"

  if start_pos[2] == 0 and end_pos[2] == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = vim.fn.visualmode() })
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local text = table.concat(lines, '\n')
  if text == '' then
    return nil
  end

  return {
    text = text,
    file = vim.fn.expand '%:p',
    start_line = start_pos[2],
    end_line = end_pos[2],
    ft = vim.bo.filetype,
  }
end

--- Open the Codex send dialog as two floating windows.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local codex = require 'codex-send'
  local selection = opts.selection
  local sending = false
  local source = opts.source
    or {
      file = vim.fn.expand '%:p',
      ft = vim.bo.filetype,
      buf = vim.api.nvim_get_current_buf(),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    }
  local file = source.file
  local ft = source.ft
  local send_buffer = false
  local source_buf = source.buf
  local buf_lines = source.lines

  -- Build info lines
  local file_info = 'File: ' .. (file ~= '' and file or '(no file)')
  local context_info
  if selection then
    local n = select(2, selection.text:gsub('\n', '')) + 1
    context_info = string.format('Selection: %d lines (%d-%d)', n, selection.start_line, selection.end_line)
  else
    context_info = 'Send buffer: [ ] (Tab to toggle)'
  end

  -- Layout
  if vim.o.lines < 12 or vim.o.columns < 20 then
    vim.notify('Enlarge the editor to open the Codex prompt', vim.log.levels.WARN)
    return
  end
  local width = math.max(18, math.min(72, math.floor(vim.o.columns * 0.7)))
  local info_height = opts.target_cwd and 4 or 3
  local max_input_height = math.max(1, math.min(6, vim.o.lines - info_height - 7))
  local gap = 0 -- no gap between bubbles
  local top_row = math.floor((vim.o.lines - (info_height + 2 + gap + max_input_height + 2)) / 2)
  local col = math.floor((vim.o.columns - width - 2) / 2)

  -- Accent highlights
  local accent_hl = vim.api.nvim_get_hl(0, { name = 'Function', link = false })
  local normal_hl = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local accent_fg = accent_hl.fg
  vim.api.nvim_set_hl(0, 'CodexSendBorder', { fg = accent_fg, bg = normal_hl.bg })
  vim.api.nvim_set_hl(0, 'CodexSendTitle', { fg = accent_fg, bg = normal_hl.bg })

  -- Top bubble: info
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = 'nofile'
  local info_lines = {
    ' Thread: ' .. codex.thread_label(opts.target),
    ' ' .. file_info,
    ' ' .. context_info,
  }
  if opts.target_cwd then
    table.insert(info_lines, ' Session cwd: ' .. opts.target_cwd)
  end
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = 'editor',
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Codex ',
    title_pos = 'center',
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = 'NormalFloat:Normal,FloatBorder:CodexSendBorder,FloatTitle:CodexSendTitle'
  vim.wo[info_win].cursorline = false

  -- Bottom bubble: prompt input
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = 'nofile'
  vim.bo[input_buf].filetype = 'codex-send-prompt'
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '' })

  local input_row = top_row + info_height + 2 + gap -- +2 for info border
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Enter: send | Shift-Enter: newline | Esc: cancel ',
    title_pos = 'center',
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = 'NormalFloat:Normal,FloatBorder:CodexSendBorder,FloatTitle:CodexSendTitle'
  vim.wo[input_win].wrap = true

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    vim.api.nvim_win_set_height(input_win, new_height)
    -- Scroll so the cursor line is always visible (bottom of window)
    local cursor_line = vim.api.nvim_win_get_cursor(input_win)[1]
    local top_line = math.max(1, cursor_line - new_height + 1)
    vim.api.nvim_win_call(input_win, function()
      vim.fn.winrestview { topline = top_line }
    end)
  end

  -- Highlight the visual selection in the source buffer while the dialog is open
  local sel_ns = nil
  if selection and vim.api.nvim_buf_is_valid(source_buf) then
    sel_ns = vim.api.nvim_create_namespace 'codex_send_selection'
    for lnum = selection.start_line, selection.end_line do
      vim.api.nvim_buf_add_highlight(source_buf, sel_ns, 'Visual', lnum - 1, 0, -1)
    end
  end

  -- Start in insert mode
  vim.cmd 'noautocmd startinsert!'

  local closed = false

  local function close()
    if closed then
      return
    end
    closed = true
    vim.cmd 'noautocmd stopinsert'
    -- Remove selection highlight from source buffer
    if sel_ns and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, sel_ns, 0, -1)
    end
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, info_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, info_buf, { force = true })
  end

  local function update_context()
    if selection then
      return
    end
    local marker = send_buffer and '[x]' or '[ ]'
    local line = ' Send buffer: ' .. marker .. ' (Tab to toggle)'
    vim.bo[info_buf].modifiable = true
    vim.api.nvim_buf_set_lines(info_buf, 2, 3, false, { line })
    vim.bo[info_buf].modifiable = false
  end

  local function send()
    if sending then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local prompt_text = vim.fn.trim(table.concat(lines, '\n'))

    local message
    if selection then
      local header = string.format('%s lines %d-%d', selection.file, selection.start_line, selection.end_line)
      if prompt_text == '' then
        message = string.format('Look at this code from %s:\n\n```%s\n%s\n```', header, selection.ft, selection.text)
      else
        message = string.format('%s\n\nFrom %s:\n```%s\n%s\n```', prompt_text, header, selection.ft, selection.text)
      end
    elseif send_buffer then
      local content = table.concat(buf_lines, '\n')
      if prompt_text == '' then
        message = string.format('Look at this file %s:\n\n```%s\n%s\n```', file ~= '' and file or '(unnamed buffer)', ft, content)
      else
        message = string.format('%s\n\nFile: %s\n```%s\n%s\n```', prompt_text, file ~= '' and file or '(unnamed buffer)', ft, content)
      end
    elseif file ~= '' then
      if prompt_text == '' then
        message = string.format('Look at this file: %s', file)
      else
        message = string.format('File: %s\n\n%s', file, prompt_text)
      end
    else
      if prompt_text == '' then
        vim.notify('Nothing to send', vim.log.levels.WARN)
        return
      end
      message = prompt_text
    end

    sending = true
    vim.bo[input_buf].modifiable = false
    codex.send(message, function(err)
      if closed then
        return
      end
      if not err then
        close()
      else
        sending = false
        vim.bo[input_buf].modifiable = true
      end
    end, opts.target)
  end

  local kopts = { buffer = input_buf, noremap = true, silent = true }

  vim.keymap.set('i', '<CR>', send, kopts)
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, kopts)
  vim.keymap.set('i', '<S-CR>', '<CR>', kopts)
  vim.keymap.set({ 'i', 'n' }, '<Esc>', close, kopts)
  vim.keymap.set({ 'i', 'n' }, '<C-c>', close, kopts)
  vim.keymap.set({ 'i', 'n' }, '<Tab>', function()
    if not selection and not sending then
      send_buffer = not send_buffer
      update_context()
    end
  end, kopts)

  -- Resize window as text is typed
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
