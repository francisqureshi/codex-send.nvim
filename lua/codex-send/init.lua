local M = {}

M.config = {
  cmd = { 'codex' },
  thread = nil,
  codex_home = nil,
  remote = nil,
  profile = nil,
  resume = false,
  auto_target = true,
}

local last_sent = {}
local thread_names = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'Codex Send' })
end

-- The local title index is only a picker: queue resolves and validates the target.
-- It includes saved sessions, not just sessions that are currently running.
function M.sessions()
  local home = M.config.codex_home or vim.env.CODEX_HOME or (vim.fn.expand '~' .. '/.codex')
  local ok, lines = pcall(vim.fn.readfile, home .. '/session_index.jsonl')
  if not ok then
    return {}
  end
  local by_id = {}
  for _, line in ipairs(lines) do
    local decoded, entry = pcall(vim.json.decode, line)
    if decoded and type(entry) == 'table' and type(entry.id) == 'string' then
      by_id[entry.id] = entry
    end
  end
  local sessions = vim.tbl_values(by_id)
  table.sort(sessions, function(a, b)
    local at, bt = a.updated_at or '', b.updated_at or ''
    if at == bt then
      return a.id < b.id
    end
    return at > bt
  end)
  return sessions
end

function M.thread_label(target)
  if not target then
    return '?'
  end
  if not M.config.remote then
    for _, session in ipairs(M.sessions()) do
      if session.id == target and type(session.thread_name) == 'string' and vim.trim(session.thread_name) ~= '' then
        return session.thread_name
      end
    end
    if thread_names[target] then
      return thread_names[target]
    end
  end
  return target
end

function M.resolve_target(callback)
  if M.config.thread then
    callback(M.config.thread)
    return
  end
  if not M.config.auto_target or M.config.remote then
    M.select_thread(callback)
    return
  end
  local cwd = vim.fn.getcwd()
  local pinned = M.config.thread
  require('codex-send.discovery').list(M.config, cwd, function(err, sessions)
    -- Don't switch context underneath a directory change or a manual choice.
    if vim.fn.getcwd() ~= cwd or M.config.thread ~= pinned then
      return
    end
    local candidates = {}
    if not err then
      local function canonical(path)
        return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
      end
      local ranks = { [canonical(cwd)] = 1 }
      local rank = 1
      for parent in vim.fs.parents(cwd) do
        rank = rank + 1
        ranks[canonical(parent)] = rank
      end
      local best_rank = math.huge
      for _, session in ipairs(sessions or {}) do
        local session_rank = type(session.cwd) == 'string' and ranks[canonical(session.cwd)] or nil
        if type(session.id) == 'string' and session_rank and session_rank <= best_rank then
          if session_rank < best_rank then
            candidates = {}
            best_rank = session_rank
          end
          table.insert(candidates, session)
          if type(session.name) == 'string' and vim.trim(session.name) ~= '' then
            thread_names[session.id] = session.name
          end
        end
      end
    end
    if #candidates == 0 then
      M.select_thread(callback)
      return
    end
    local chosen = candidates[1]
    for _, session in ipairs(candidates) do
      if session.id == last_sent[cwd] then
        chosen = session
        break
      end
    end
    callback(chosen.id, { cwd = chosen.cwd })
  end)
end

function M.select_thread(callback)
  local items = { { manual = true } }
  if not M.config.remote then
    vim.list_extend(items, M.sessions())
  end
  local function select(target)
    if not target or vim.trim(target) == '' then
      return
    end
    M.config.thread = vim.trim(target)
    notify('Target: ' .. M.config.thread)
    if callback then
      callback(M.config.thread)
    end
  end
  vim.ui.select(items, {
    prompt = 'Codex thread (saved sessions; choose your running thread):',
    format_item = function(item)
      if item.manual then
        return 'Enter session UUID or exact name…'
      end
      return string.format('%s  [%s]  %s', item.thread_name or '(untitled)', item.id, item.updated_at or '')
    end,
  }, function(item)
    if not item then
      return
    end
    if item.manual then
      vim.ui.input({ prompt = 'Codex session UUID or exact name: ' }, select)
    else
      select(item.id)
    end
  end)
end

function M.send(message, callback, target)
  callback = callback or function() end
  if not message or vim.trim(message) == '' then
    callback 'Nothing to send'
    return
  end
  target = target or M.config.thread
  if not target then
    M.resolve_target(function(thread)
      M.send(message, callback, thread)
    end)
    return
  end
  local cwd = vim.fn.getcwd()
  local argv = vim.deepcopy(M.config.cmd)
  vim.list_extend(argv, { 'queue', '--thread', target, '--message', message })
  if M.config.remote then
    vim.list_extend(argv, { '--remote', M.config.remote })
  end
  if M.config.profile then
    vim.list_extend(argv, { '--profile', M.config.profile })
  end
  if M.config.resume then
    table.insert(argv, '--resume')
  end
  local env = M.config.codex_home and { CODEX_HOME = M.config.codex_home } or nil
  local ok, err = pcall(vim.system, argv, { text = true, env = env }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = vim.trim(result.stderr or '')
        if detail == '' then
          detail = vim.trim(result.stdout or '')
        end
        local failure = 'Queue failed: ' .. (detail ~= '' and detail or ('exit ' .. result.code))
        notify(failure, vim.log.levels.ERROR)
        callback(failure)
        return
      end
      -- Successful queueing isn't a guarantee that the thread has consumed it.
      last_sent[cwd] = target
      notify('Queued for ' .. target)
      local warning = vim.trim(result.stderr or '')
      if warning ~= '' then
        notify(warning, vim.log.levels.WARN)
      end
      callback(nil)
    end)
  end)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
    callback(tostring(err))
  end
end

function M.open(selection)
  local source = {
    buf = vim.api.nvim_get_current_buf(),
    file = vim.fn.expand '%:p',
    ft = vim.bo.filetype,
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  }
  local function open(target, match)
    require('codex-send.ui').open { selection = selection, target = target, source = source, target_cwd = match and match.cwd }
  end
  M.resolve_target(open)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  vim.api.nvim_create_user_command('Codex', function(args)
    local selection = args.range > 0 and require('codex-send.ui').capture_selection() or nil
    M.open(selection)
  end, { range = true, desc = 'Send context and a prompt to an existing Codex thread' })
  vim.api.nvim_create_user_command('CodexSendSelection', function()
    local selection = require('codex-send.ui').capture_selection()
    if not selection then
      notify('No visual selection', vim.log.levels.WARN)
      return
    end
    M.open(selection)
  end, { range = true, desc = 'Send selection to Codex' })
  vim.api.nvim_create_user_command('CodexSessions', function()
    M.select_thread()
  end, { desc = 'Choose a Codex thread' })
  vim.api.nvim_create_user_command('CodexTarget', function(args)
    if args.args == 'auto' then
      M.config.thread = nil
      M.config.auto_target = true
      notify 'Automatic targeting enabled'
    elseif args.args == '' then
      M.resolve_target(function(target)
        notify('Target: ' .. M.thread_label(target))
      end)
    else
      M.config.thread = vim.trim(args.args)
      notify('Target: ' .. M.config.thread)
    end
  end, { nargs = '*', desc = 'Show or set the target session UUID or exact name' })
end

return M
