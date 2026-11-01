vim.opt.runtimepath:prepend(vim.fn.getcwd())
local codex = require 'codex-send'
local ui = require 'codex-send.ui'
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local notices = {}
vim.notify = function(message)
  table.insert(notices, message)
end
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect { actual = actual, expected = expected })
end
local function wait_for(predicate)
  assert(vim.wait(5000, predicate, 10), 'Timed out')
end
local function key(lhs)
  for _, mode in ipairs { 'i', 'n' } do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
      if map.lhs == lhs then
        return map.callback()
      end
    end
  end
  error('No mapping for ' .. lhs)
end

local ok, err = xpcall(function()
  -- Real subprocess boundary: shell syntax and multiline Unicode stay literal.
  local fake = tmp .. '/fake.py'
  vim.fn.writefile({
    'import json, pathlib, sys',
    'pathlib.Path(__file__).with_suffix(".json").write_text(json.dumps(sys.argv[1:]))',
    'if "fail" in sys.argv:',
    '    print("test queue failure", file=sys.stderr)',
    '    sys.exit(1)',
  }, fake)
  codex.setup { cmd = { 'python3', fake }, codex_home = tmp, thread = 'chosen-thread' }
  local message = 'Explain λ\n`touch nope` $(touch nope) "quoted"'
  local complete = false
  codex.send(message, function(failure)
    assert(not failure, failure)
    complete = true
  end)
  wait_for(function()
    return complete
  end)
  eq(vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/fake.json'), '\n')), { 'queue', '--thread', 'chosen-thread', '--message', message })

  -- Dedup renamed threads, skip partial writes, sort by recency.
  vim.fn.writefile({
    vim.json.encode { id = 'old', thread_name = 'before', updated_at = '2026-01-01' },
    '{partial',
    vim.json.encode { id = 'new', thread_name = 'newest', updated_at = '2026-11-01' },
    vim.json.encode { id = 'old', thread_name = 'renamed', updated_at = '2026-10-01' },
  }, tmp .. '/session_index.jsonl')
  local sessions = codex.sessions()
  eq(#sessions, 2)
  eq({ sessions[1].id, sessions[2].thread_name }, { 'new', 'renamed' })

  -- A canceled picker sends nothing and doesn't silently pick the newest thread.
  local select = vim.ui.select
  vim.ui.select = function(_, _, callback)
    callback(nil)
  end
  local selected = false
  codex.select_thread(function()
    selected = true
  end)
  assert(not selected)
  eq(codex.config.thread, 'chosen-thread')
  vim.ui.select = select

  vim.cmd 'enew'
  vim.api.nvim_buf_set_name(0, tmp .. '/source.lua')
  vim.bo.filetype = 'lua'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local value = 42', 'print(value)' })
  -- Exercise real visual marks/getregion, including characterwise endpoints.
  vim.cmd.normal { args = { 'gg0v4l' }, bang = true }
  vim.cmd.normal { args = { vim.api.nvim_replace_termcodes('<Esc>', true, false, true) }, bang = true }
  local selection = ui.capture_selection()
  eq(selection.text, 'local')
  eq(selection.file, tmp .. '/source.lua')

  -- A dialog pins its target, even if the global target changes before submit.
  codex.open(selection)
  local draft = vim.api.nvim_get_current_buf()
  codex.config.thread = 'different-thread'
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'Explain this' })
  key '<CR>'
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(draft)
  end)
  local argv = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/fake.json'), '\n'))
  eq(argv[3], 'chosen-thread')
  assert(argv[5]:find('local', 1, true))
  assert(argv[5]:find('source.lua lines 1-1', 1, true))

  -- Queue failure preserves the editable draft for retry.
  codex.config.thread = 'fail'
  codex.open()
  draft = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'Keep this draft' })
  key '<CR>'
  wait_for(function()
    return vim.bo[draft].modifiable
  end)
  eq(vim.api.nvim_buf_get_lines(draft, 0, -1, false), { 'Keep this draft' })
  key '<Esc>'
  assert(not vim.api.nvim_buf_is_valid(draft))

  -- Buffer toggle includes unsaved source text rather than just a file reference.
  codex.config.thread = 'chosen-thread'
  codex.open()
  draft = vim.api.nvim_get_current_buf()
  key '<Tab>'
  key '<CR>'
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(draft)
  end)
  argv = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/fake.json'), '\n'))
  assert(argv[5]:find('local value = 42\nprint(value)', 1, true))
end, debug.traceback)
vim.fn.delete(tmp, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd 'cquit 1'
end
print 'Codex Send checks passed (fake CLI; no live messages sent)'
vim.cmd 'qa!'
