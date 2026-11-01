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
    'if "app-server" in sys.argv:',
    '    for line in sys.stdin:',
    '        request = json.loads(line)',
    '        if request["method"] == "initialize":',
    '            reply = {"id": 1, "result": {}}',
    '        elif request["method"] == "thread/list":',
    '            assert request["params"]["archived"] is False',
    '            assert request["params"]["sortKey"] == "recency_at"',
    '            sessions = json.loads(pathlib.Path(__file__).with_suffix(".sessions.json").read_text())',
    '            matches = [s for s in sessions if s["cwd"] in request["params"]["cwd"]]',
    '            reply = {"id": 2, "result": {"data": matches}}',
    '        else:',
    '            assert request["method"] == "initialized"',
    '            continue',
    '        payload = json.dumps(reply) + "\\n"',
    '        sys.stdout.write(payload[:8]); sys.stdout.flush()',
    '        sys.stdout.write(payload[8:]); sys.stdout.flush()',
    '    sys.exit(0)',
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

  -- The full-width composer shows only the session and editable prompt.
  ui.open {
    target = 'chosen-thread',
    target_cwd = tmp,
    source = { buf = vim.api.nvim_get_current_buf(), file = string.rep('a', 200), ft = 'lua', lines = { '' } },
  }
  local prompt_buf = vim.api.nvim_get_current_buf()
  local prompt_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= '' then
      eq(config.width, vim.o.columns)
      eq(config.col, 0)
      assert(config.border == nil or config.border == 'none')
      assert(config.title == nil and config.footer == nil)
      if config.focusable == false then
        eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), { ' ֎ chosen-thread' })
      end
    end
  end
  local marks = vim.api.nvim_buf_get_extmarks(prompt_buf, vim.api.nvim_create_namespace 'codex_send_chevron', 0, -1, { details = true })
  eq(marks[1][4].sign_text, '❯ ')
  local config = vim.api.nvim_win_get_config(prompt_win)
  eq(config.row + config.height, vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0))

  -- Help is a separate splash, and returning keeps the exact draft buffer.
  key '?'
  wait_for(function()
    return vim.bo.filetype == 'codex-send-help'
  end)
  local help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  assert(help:find('Ctrl-T', 1, true))
  assert(help:find('Session cwd: ' .. tmp, 1, true))
  key '<Esc>'
  eq(vim.api.nvim_get_current_buf(), prompt_buf)
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { 'A question' })
  eq(key '?', '?') -- ordinary question marks in a message remain literal
  key '<Esc>'

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

  -- Switching sessions through an asynchronous picker preserves the draft/selection.
  codex.config.thread = 'chosen-thread'
  codex.open(selection)
  draft = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'Keep my prompt' })
  local choose, items, picker_win, picker_buf
  vim.ui.select = function(values, _, callback)
    items, choose = values, callback
    picker_buf = vim.api.nvim_create_buf(false, true)
    picker_win = vim.api.nvim_open_win(picker_buf, true, {
      relative = 'editor',
      row = 0,
      col = 0,
      width = 20,
      height = 2,
    })
  end
  key '<C-T>'
  vim.wait(20, function()
    return false
  end)
  assert(vim.api.nvim_buf_is_valid(draft), 'Picker must not discard draft on BufLeave')
  vim.api.nvim_win_close(picker_win, true)
  vim.api.nvim_buf_delete(picker_buf, { force = true })
  choose(items[2])
  eq(vim.api.nvim_get_current_buf(), draft)
  eq(vim.api.nvim_buf_get_lines(draft, 0, -1, false), { 'Keep my prompt' })
  eq(codex.config.thread, 'new')

  -- Canceling a second picker keeps the chosen target and the prompt.
  vim.ui.select = function(_, _, callback)
    callback(nil)
  end
  key '<C-T>'
  eq(codex.config.thread, 'new')
  eq(vim.api.nvim_get_current_buf(), draft)
  vim.ui.select = select
  key '<CR>'
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(draft)
  end)
  argv = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/fake.json'), '\n'))
  eq(argv[3], 'new')
  assert(argv[5]:find('Keep my prompt', 1, true))
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

  -- Real discovery protocol; exact directory matches win over ancestors.
  local cwd = vim.fn.getcwd()
  local other = tmp .. '/other'
  vim.fn.mkdir(other, 'p')
  vim.fn.writefile({
    vim.json.encode {
      { id = 'wrong-directory', cwd = cwd .. '-sibling', name = 'Wrong project' },
      { id = 'broader-project', cwd = vim.fs.dirname(cwd), name = 'Parent should lose to exact' },
      { id = 'other-directory', cwd = other, name = 'Other project' },
      { id = 'auto-new', cwd = cwd, name = 'Recent project session' },
      { id = 'auto-old', cwd = cwd, name = 'Older project session' },
    },
  }, tmp .. '/fake.sessions.json')
  codex.config.thread = nil
  local function resolve()
    local target
    codex.resolve_target(function(value)
      target = value
    end)
    wait_for(function()
      return target ~= nil
    end)
    return target
  end
  eq(resolve(), 'auto-new')
  eq(codex.thread_label 'auto-new', 'Recent project session')
  assert(codex.config.thread == nil, 'Automatic targeting must not pin a thread')

  complete = false
  codex.send('Remember this target', function(failure)
    assert(not failure, failure)
    complete = true
  end, 'auto-old')
  wait_for(function()
    return complete
  end)
  eq(resolve(), 'auto-old')

  vim.cmd.cd(other)
  eq(resolve(), 'other-directory')
  vim.cmd.cd(cwd)
  eq(resolve(), 'auto-old')
  codex.config.thread = 'explicit-choice'
  eq(resolve(), 'explicit-choice')
  vim.cmd 'CodexTarget auto'
  eq(resolve(), 'auto-old')

  -- A Codex session can be rooted above the project Neovim is editing.
  local parent = vim.fs.dirname(cwd)
  vim.fn.writefile({
    vim.json.encode {
      { id = 'distant-ancestor', cwd = vim.fs.dirname(parent), name = 'Distant ancestor' },
      { id = 'parent-session', cwd = parent, name = 'Parent directory session' },
    },
  }, tmp .. '/fake.sessions.json')
  local fallback, parent_target = false, nil
  vim.ui.select = function(_, _, callback)
    fallback = true
    callback(nil)
  end
  codex.resolve_target(function(target)
    parent_target = target
  end)
  wait_for(function()
    return fallback or parent_target ~= nil
  end)
  eq(parent_target, 'parent-session')
  vim.ui.select = select

  -- With no cwd match (or discovery failure), use the picker, never global latest.
  local picked = 0
  vim.ui.select = function(_, _, callback)
    picked = picked + 1
    callback(nil)
  end
  vim.fn.writefile({ '[]' }, tmp .. '/fake.sessions.json')
  codex.resolve_target(function()
    error 'Should not automatically choose a thread'
  end)
  wait_for(function()
    return picked == 1
  end)
  vim.fn.delete(tmp .. '/fake.sessions.json')
  codex.resolve_target(function()
    error 'Discovery failure must not choose a thread'
  end)
  wait_for(function()
    return picked == 2
  end)
  vim.ui.select = select
end, debug.traceback)
vim.fn.delete(tmp, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd 'cquit 1'
end
print 'Codex Send checks passed (fake CLI; no live messages sent)'
vim.cmd 'qa!'
