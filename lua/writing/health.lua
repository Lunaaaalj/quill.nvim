-- :checkhealth writing

local M = {}

local function run(cmd, timeout)
  local ok, res = pcall(function() return vim.system(cmd, { text = true, timeout = timeout }):wait() end)
  if ok then return res end
end

function M.check()
  local h = vim.health
  local c = require("writing.config").options

  h.start("quill.nvim: spell audit")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
  end
  local sl = vim.bo.spelllang ~= "" and vim.bo.spelllang or vim.o.spelllang
  h.info(("'spelllang' is %s; 'spellfile' is %s"):format(sl, vim.o.spellfile ~= "" and vim.o.spellfile or "(default)"))

  h.start("quill.nvim: Claude")
  local cmd = c.claude.command
  if vim.fn.executable(cmd) == 0 then
    return h.error(cmd .. " not found", {
      "Install Claude Code (https://claude.com/claude-code); only the spell audit works without it",
    })
  end
  local v = run({ cmd, "--version" }, 5000)
  h.ok(cmd .. ": " .. (v and v.code == 0 and vim.trim(v.stdout) or "found"))

  local st = run({ cmd, "auth", "status" }, 8000)
  local okj, auth = pcall(vim.json.decode, st and st.stdout or "")
  if okj and type(auth) == "table" and auth.loggedIn then
    h.ok("logged in (" .. tostring(auth.authMethod or "?") .. ")")
  elseif okj and type(auth) == "table" then
    h.error("not logged in", { "Run `" .. cmd .. "` once and log in (or `" .. cmd .. " auth login`)" })
  else
    h.warn("couldn't read `" .. cmd .. " auth status`; a test request will tell", {
      "Older Claude Code versions don't have `auth status`",
    })
  end

  if vim.tbl_contains(c.claude.args or {}, "--bare") then
    h.error("claude.args contains --bare", { "--bare skips keychain reads, so it can't use your login: remove it" })
  end

  h.info(("models: grammar %s/%s, outline %s/%s, rigor %s/%s, assist %s/%s"):format(
    c.grammar.model, c.grammar.effort, c.outline.model, c.outline.effort,
    c.rigor.model, c.rigor.effort, c.assist.model, c.assist.effort))
  if vim.g.writing_health_request ~= true then
    return h.info("Set `vim.g.writing_health_request = true` to also send a one-word test request")
  end
  local done, err, val = false, nil, nil
  require("writing.claude").run({
    prompt = "Reply with the word ok.", system = "You answer in one word.", model = c.grammar.model,
  }, function(e, r) done, err, val = true, e, r end)
  vim.wait(c.claude.timeout, function() return done end, 100)
  if not done then
    h.error("test request timed out")
  elseif err then
    h.error("test request failed: " .. err)
  else
    h.ok("test request answered: " .. vim.trim(tostring(val)):sub(1, 40))
  end
end

return M
