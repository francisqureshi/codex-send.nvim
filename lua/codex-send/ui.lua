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

function M.refresh_highlights()
  -- A single quiet surface, slightly darker than the editor background.
  local normal_hl = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local float_hl = vim.api.nvim_get_hl(0, { name = 'NormalFloat', link = false })
  local comment_hl = vim.api.nvim_get_hl(0, { name = 'Comment', link = false })
  local accent_hl = vim.api.nvim_get_hl(0, { name = require('codex-send').config.accent_hl, link = false })
  local base = normal_hl.bg or float_hl.bg or 0x202020
  local function shade(channel)
    return math.floor(channel * 0.9)
  end
  local background = shade(math.floor(base / 65536) % 256) * 65536 + shade(math.floor(base / 256) % 256) * 256 + shade(base % 256)
  if background == base then
    background = 0x080808
  end
  vim.api.nvim_set_hl(0, 'CodexSendPanel', { fg = normal_hl.fg, bg = background })
  vim.api.nvim_set_hl(0, 'CodexSendMeta', { fg = comment_hl.fg or normal_hl.fg, bg = background })

  vim.api.nvim_set_hl(0, 'CodexSendAccent', { fg = accent_hl.fg or normal_hl.fg, bg = background })
end

vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('codex_send_theme', { clear = true }),
  callback = function()
    M.refresh_highlights()
  end,
})

--- Open a borderless composer with contiguous metadata and input surfaces.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local codex = require 'codex-send'
  local selection = opts.selection
  local sending = false
  local picking = false
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

  -- Layout
  if vim.o.lines < 12 or vim.o.columns < 20 then
    vim.notify('Enlarge the editor to open the Codex prompt', vim.log.levels.WARN)
    return
  end
  local width = vim.o.columns
  local info_height = 1
  local max_input_height = math.max(1, math.min(6, vim.o.lines - info_height - 3))
  local function bottom_row()
    return vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  end
  local top_row = bottom_row() - info_height - 1
  local col = 0

  M.refresh_highlights()

  -- Metadata and input meet edge-to-edge with the same background.
  local info_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[info_buf].buftype = 'nofile'
  local function session_heading()
    local icon = codex.config.session_icon
    return ' ' .. (icon ~= '' and (icon .. ' ') or '') .. codex.thread_label(opts.target)
  end
  local info_lines = { session_heading() }
  vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
  vim.bo[info_buf].modifiable = false

  local info_win = vim.api.nvim_open_win(info_buf, false, {
    relative = 'editor',
    width = width,
    height = info_height,
    row = top_row,
    col = col,
    style = 'minimal',
    border = 'none',
    zindex = 50,
    noautocmd = true,
    focusable = false,
  })
  vim.wo[info_win].winhl = 'NormalFloat:CodexSendAccent,Normal:CodexSendAccent,EndOfBuffer:CodexSendPanel'
  vim.wo[info_win].winblend = 0
  vim.wo[info_win].cursorline = false
  -- Keep one display row per field so long paths/titles cannot hide metadata.
  vim.wo[info_win].wrap = false

  -- Editable message, without window chrome.
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = 'nofile'
  vim.bo[input_buf].filetype = 'codex-send-prompt'
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '' })

  local input_row = top_row + info_height
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = input_row,
    col = col,
    style = 'minimal',
    border = 'none',
    zindex = 50,
    noautocmd = true,
  })
  vim.wo[input_win].winhl = 'NormalFloat:CodexSendPanel,Normal:CodexSendPanel,EndOfBuffer:CodexSendPanel,SignColumn:CodexSendPanel'
  vim.wo[input_win].winblend = 0
  vim.wo[input_win].signcolumn = 'yes:1'
  vim.wo[input_win].wrap = true
  vim.api.nvim_buf_set_extmark(input_buf, vim.api.nvim_create_namespace 'codex_send_chevron', 0, 0, {
    sign_text = '❯',
    sign_hl_group = 'CodexSendAccent',
    priority = 100,
    right_gravity = false,
  })

  -- Resize the input window to fit content (1..max_input_height rows)
  local function resize_input()
    if not vim.api.nvim_win_is_valid(input_win) then
      return
    end
    width = vim.o.columns
    max_input_height = math.max(1, math.min(6, vim.o.lines - info_height - 3))
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    -- Count visual rows (each buffer line may wrap across multiple display rows)
    local visual_rows = 0
    for _, line in ipairs(lines) do
      -- A blank line still takes 1 row
      visual_rows = visual_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width - 2)))
    end
    local new_height = math.max(1, math.min(max_input_height, visual_rows))
    local row = math.max(0, bottom_row() - new_height)
    vim.api.nvim_win_set_config(input_win, { relative = 'editor', row = row, col = col, width = width, height = new_height })
    if vim.api.nvim_win_is_valid(info_win) then
      vim.api.nvim_win_set_config(info_win, {
        relative = 'editor',
        row = math.max(0, row - info_height),
        col = col,
        width = width,
      })
    end
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

  local function send()
    if sending or picking then
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

  local function show_help()
    if closed or sending or picking then
      return
    end
    picking = true
    vim.cmd 'noautocmd stopinsert'
    local help_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[help_buf].filetype = 'codex-send-help'
    local context = selection and 'Selection attached'
      or (send_buffer and 'Full buffer attached' or (file ~= '' and 'File reference attached' or 'Prompt only'))
    local lines = {
      ' Codex',
      '',
      ' Enter / Ctrl-S   Send',
      ' Shift-Enter      New line',
      ' Ctrl-T           Choose session',
      selection and ' Tab              Selection attached (buffer toggle disabled)' or ' Tab              Toggle full buffer',
      ' Esc / Ctrl-C     Cancel',
      ' ?                Help (empty prompt or Normal mode)',
      '',
      ' Session: ' .. codex.thread_label(opts.target),
      ' File: ' .. (file ~= '' and file or '(unnamed buffer)'),
      ' Context: ' .. context,
      ' Session cwd: ' .. (opts.target_cwd or '(manually selected)'),
      '',
      ' Esc / Enter / q  Return to prompt',
    }
    vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
    vim.bo[help_buf].modifiable = false
    local help_width = math.min(60, vim.o.columns - 4)
    local help_height = math.min(#lines, vim.o.lines - 4)
    local help_win = vim.api.nvim_open_win(help_buf, true, {
      relative = 'editor',
      style = 'minimal',
      border = 'none',
      zindex = 60,
      width = help_width,
      height = help_height,
      row = math.max(0, math.floor((vim.o.lines - help_height) / 2)),
      col = math.max(0, math.floor((vim.o.columns - help_width) / 2)),
    })
    vim.wo[help_win].winhl = 'NormalFloat:CodexSendPanel,Normal:CodexSendPanel,EndOfBuffer:CodexSendPanel'
    vim.wo[help_win].wrap = false
    local dismissed = false
    local function dismiss()
      if dismissed then
        return
      end
      dismissed = true
      pcall(vim.api.nvim_win_close, help_win, true)
      pcall(vim.api.nvim_buf_delete, help_buf, { force = true })
      picking = false
      if not closed and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_set_current_win(input_win)
        vim.cmd 'noautocmd startinsert!'
      end
    end
    for _, key in ipairs { '<Esc>', '<C-c>', '<CR>', 'q', '?' } do
      vim.keymap.set('n', key, dismiss, { buffer = help_buf, silent = true })
    end
    vim.api.nvim_create_autocmd('BufLeave', {
      buffer = help_buf,
      once = true,
      callback = function()
        vim.schedule(dismiss)
      end,
    })
  end

  vim.keymap.set('n', '?', show_help, kopts)
  vim.keymap.set('i', '?', function()
    local text = table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), '\n')
    if text == '' then
      vim.schedule(show_help)
      return ''
    end
    return '?'
  end, { buffer = input_buf, silent = true, expr = true })

  vim.keymap.set({ 'i', 'n' }, '<C-t>', function()
    if sending or picking then
      return
    end
    picking = true
    vim.cmd 'noautocmd stopinsert'
    local function restore()
      picking = false
      if closed or not vim.api.nvim_win_is_valid(input_win) then
        return
      end
      vim.api.nvim_set_current_win(input_win)
      vim.cmd 'noautocmd startinsert!'
    end
    codex.select_thread(function(target)
      if not closed then
        opts.target = target
        vim.bo[info_buf].modifiable = true
        vim.api.nvim_buf_set_lines(info_buf, 0, 1, false, { session_heading() })
        opts.target_cwd = nil
        vim.bo[info_buf].modifiable = false
      end
      restore()
    end, restore)
  end, kopts)

  vim.keymap.set('i', '<CR>', send, kopts)
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, kopts)
  vim.keymap.set('i', '<S-CR>', '<CR>', kopts)
  vim.keymap.set({ 'i', 'n' }, '<Esc>', close, kopts)
  vim.keymap.set({ 'i', 'n' }, '<C-c>', close, kopts)
  vim.keymap.set({ 'i', 'n' }, '<Tab>', function()
    if not selection and not sending then
      send_buffer = not send_buffer
    end
  end, kopts)

  -- Resize window as text is typed
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer = input_buf,
    callback = resize_input,
  })

  vim.api.nvim_create_autocmd('VimResized', { buffer = input_buf, callback = resize_input })

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = input_buf,
    callback = function()
      if not picking then
        vim.schedule(function()
          if not picking then
            close()
          end
        end)
      end
    end,
  })
end

return M
