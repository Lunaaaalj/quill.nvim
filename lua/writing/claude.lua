-- Headless Claude for the writing tools: `claude -p` with your Claude Code
-- login, so no API key is needed (and usage counts against your plan).
--
--   * the prompt goes on stdin; `--system-prompt` replaces Claude Code's own
--     (much longer) one, `--tools ""` gives the model no tools, and nothing is
--     saved as a session;
--   * `--json-schema` makes the answer schema-valid JSON, returned in the
--     envelope's `structured_output`;
--   * it runs in an empty directory under stdpath("cache"), so no CLAUDE.md
--     (yours or a project's) is read into the request;
--   * `--bare` would be leaner but skips keychain reads, i.e. the login.

local M = {}

local function cfg() return require("writing.config").options.claude end

local queue, running = {}, 0

local function workdir()
  local dir = vim.fn.stdpath("cache") .. "/writing/cwd"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function pump()
  while running < cfg().max_jobs and #queue > 0 do
    local job = table.remove(queue, 1)
    running = running + 1
    job(function()
      running = running - 1
      pump()
    end)
  end
end

--- Ask Claude. `o`: { prompt, system, schema?, model?, effort? }.
--- cb(err, value): `value` is the decoded JSON when `schema` is given, else text.
function M.run(o, cb)
  local c = cfg()
  local cmd = {
    c.command, "-p", "--output-format", "json",
    "--model", o.model or "haiku",
    "--tools", "", "--no-session-persistence",
    "--system-prompt", o.system,
  }
  if o.effort then vim.list_extend(cmd, { "--effort", o.effort }) end
  if o.schema then vim.list_extend(cmd, { "--json-schema", vim.json.encode(o.schema) }) end
  vim.list_extend(cmd, c.args or {})
  if vim.fn.executable(cmd[1]) == 0 then
    return cb(("`%s` not found: the writing tools use Claude Code's CLI"):format(cmd[1]))
  end

  queue[#queue + 1] = function(release)
    local ok, err = pcall(vim.system, cmd, {
      text = true, stdin = o.prompt, cwd = workdir(), timeout = c.timeout,
    }, vim.schedule_wrap(function(res)
      release()
      if res.code == 124 then return cb("Claude timed out") end
      local okj, env = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
      if not okj or type(env) ~= "table" then
        local msg = vim.trim(res.stderr or "")
        return cb(msg ~= "" and msg or ("claude returned no JSON (exit %d)"):format(res.code))
      end
      if env.is_error or (env.subtype and env.subtype ~= "success") then
        return cb(tostring(env.result or env.subtype or "Claude reported an error"))
      end
      if not o.schema then return cb(nil, env.result or "") end
      if type(env.structured_output) == "table" then return cb(nil, env.structured_output) end
      local okr, v = pcall(vim.json.decode, env.result or "", { luanil = { object = true, array = true } })
      if okr and type(v) == "table" then return cb(nil, v) end
      cb("Claude's answer didn't match the expected JSON")
    end))
    if not ok then
      release()
      cb(tostring(err))
    end
  end
  pump()
end

return M
