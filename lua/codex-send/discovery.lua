local M = {}

-- Query metadata only. Never resume a thread or start a model turn.
function M.list(config, cwd, callback)
  local argv = vim.deepcopy(config.cmd)
  if config.profile then
    vim.list_extend(argv, { '--profile', config.profile })
  end
  vim.list_extend(argv, { 'app-server', '--listen', 'stdio://' })
  local job, timer, done
  local pending = ''
  local function finish(err, sessions)
    if done then
      return
    end
    done = true
    if timer then
      timer:stop()
      timer:close()
    end
    if job and job > 0 then
      pcall(vim.fn.jobstop, job)
    end
    callback(err, sessions)
  end
  local function write(message)
    local ok, err = pcall(vim.fn.chansend, job, vim.json.encode(message) .. '\n')
    if not ok then
      finish(tostring(err))
    end
  end
  local paths = { cwd }
  local real = vim.uv.fs_realpath(cwd)
  if real and real ~= cwd then
    table.insert(paths, real)
  end
  local function receive(line)
    local ok, response = pcall(vim.json.decode, line)
    if not ok or type(response) ~= 'table' then
      return
    end
    if response.id ~= 1 and response.id ~= 2 then
      return
    end
    if response.error then
      finish(response.error.message or 'Discovery failed')
      return
    end
    if response.id == 1 then
      write { method = 'initialized' }
      write {
        id = 2,
        method = 'thread/list',
        params = {
          cwd = paths,
          limit = 50,
          sortKey = 'recency_at',
          sortDirection = 'desc',
          archived = false,
          useStateDbOnly = true,
          sourceKinds = { 'cli', 'vscode', 'appServer', 'unknown' },
        },
      }
    elseif type(response.result) == 'table' and type(response.result.data) == 'table' then
      finish(nil, response.result.data)
    else
      finish 'Invalid thread list'
    end
  end
  local ok, result = pcall(vim.fn.jobstart, argv, {
    env = config.codex_home and { CODEX_HOME = config.codex_home } or nil,
    on_stdout = function(_, data)
      if done then
        return
      end
      pending = pending .. table.concat(data, '\n')
      while not done do
        local pos = pending:find('\n', 1, true)
        if not pos then
          break
        end
        local line = pending:sub(1, pos - 1)
        pending = pending:sub(pos + 1)
        receive(line)
      end
    end,
    on_exit = function()
      finish 'Discovery process exited'
    end,
  })
  if not ok or result <= 0 then
    finish 'Cannot start Codex session discovery'
    return
  end
  job = result
  timer = vim.uv.new_timer()
  timer:start(
    4000,
    0,
    vim.schedule_wrap(function()
      finish 'Session discovery timed out'
    end)
  )
  write { id = 1, method = 'initialize', params = {
    clientInfo = { name = 'codex_send_nvim', version = '0.1.0' },
  } }
end

return M
