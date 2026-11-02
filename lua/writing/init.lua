-- quill.nvim: a proofreading kit. A spell audit that walks every spelling
-- issue (offline), and Claude (a cheap model, through the `claude` CLI and
-- your Claude Code login) as copy editor, developmental editor and reader.
--
--   spell       walk every spelling issue (]s + spellbadword) in a float
--   grammar     grammar audit (+ style), walked like the spell audit;
--               issues are also diagnostics
--   outline     reverse outline: summary, role and flags per paragraph
--   conform     check the text against the rules of your STYLE.md (walk)
--   restyle     rewrite every paragraph to follow your STYLE.md (diff walk)
--   rigor       peer review: loose arguments, unsupported or overclaimed
--               statements, fallacies, inconsistencies (report + walk)
--   rewrite/ask on the selection or the paragraph under the cursor
--   chat        companion chat in a split
--
-- Nothing runs on its own: text only leaves Neovim when you ask. Results are
-- cached, so repeating a pass only sends what changed. Modules: claude.lua
-- (CLI), prose.lua (paragraphs), issues.lua (quote-anchored findings, talk),
-- walker.lua (the audit float, later), facts.lua (what suggestions may not
-- invent), spell.lua, grammar.lua, conform.lua, restyle.lua, rigor.lua,
-- outline.lua, assist.lua. Commands and <Plug> maps:
-- plugin/quill.lua. Every Claude action takes `o.model` / `o.effort`.

local M = {}

local api = vim.api
local did_setup = false

--- Configure (optional: the defaults apply without it). Safe to call again.
function M.setup(opts)
  require("writing.config").setup(opts)
  require("writing.hl").setup()
  if not did_setup then
    require("writing.issues").setup()
    require("writing.outline").setup()
    require("writing.rigor").setup()
  end
  did_setup = true
end

--- setup() with the defaults, unless it already ran.
function M.ensure()
  if not did_setup then M.setup() end
end

--- The key mapped to `plug` (e.g. "<Plug>(SpellAudit)"), else `fallback`:
--- used in "… again resumes" hints, since the keys are yours to choose.
function M.hint(plug, fallback)
  for _, m in ipairs(api.nvim_get_keymap("n")) do
    if m.rhs == plug and not m.lhs:find("<Plug>", 1, true) then
      local leader = vim.g.mapleader or "\\"
      if m.lhs:sub(1, #leader) == leader then return "<leader>" .. vim.fn.keytrans(m.lhs:sub(#leader + 1)) end
      return vim.fn.keytrans(m.lhs)
    end
  end
  return fallback
end

-- ---------------------------------------------------------------------------
-- actions (what the commands and <Plug> maps call)

function M.spell() M.ensure(); require("writing.spell").start() end

--- Grammar audit. `o.style` adds style/clarity hints, `o.range` = { s, e } rows.
function M.grammar(o) M.ensure(); require("writing.grammar").audit(o or {}) end

function M.paragraph(o)
  local row = api.nvim_win_get_cursor(0)[1]
  M.grammar(vim.tbl_extend("force", o or {}, { range = { row, row } }))
end

function M.outline(o) M.ensure(); require("writing.outline").open(o) end

function M.rigor(o) M.ensure(); require("writing.rigor").review(o) end

--- STYLE.md conformance: findings cite the rule they break.
function M.conform(o) M.ensure(); require("writing.conform").audit(o or {}) end

--- STYLE.md paragraph rewrites, walked as diffs.
function M.restyle(o) M.ensure(); require("writing.restyle").audit(o or {}) end

-- Load every store, so counts and lists see them all.
local function stores()
  for _, m in ipairs({ "grammar", "conform", "restyle", "rigor" }) do require("writing." .. m) end
  return require("writing.issues")
end

--- The findings that need your input (facts the model may not invent) in
--- this buffer, in the quickfix list.
function M.needs()
  M.ensure()
  local items = stores().needs_items(api.nvim_get_current_buf())
  if #items == 0 then
    return vim.notify("Nothing needs your input here", vim.log.levels.INFO, { title = "Writing" })
  end
  table.sort(items, function(a, b) return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col) end)
  vim.fn.setqflist({}, " ", { title = "Writing: needs your input", items = items })
  vim.cmd("copen")
end

--- { needs = n, later = n } for `buf` (default: current), for a statusline.
function M.counts(buf) return stores().counts(buf or api.nvim_get_current_buf()) end

--- Rewrite / ask: `target` true = the last visual selection, { r1, r2 } = those
--- lines (1-based), nil = the paragraph under the cursor.
function M.rewrite(target, o) M.ensure(); require("writing.assist").rewrite(target, o) end

function M.ask(target, o) M.ensure(); require("writing.assist").ask(target, o) end

--- Everything you deferred with `l` in this buffer, in the quickfix list.
function M.later()
  M.ensure()
  local buf = api.nvim_get_current_buf()
  local items = stores().later_items(buf)
  vim.list_extend(items, require("writing.spell").later_items(buf))
  table.sort(items, function(a, b) return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col) end)
  if #items == 0 then
    return vim.notify("Nothing left for later here", vim.log.levels.INFO, { title = "Writing" })
  end
  vim.fn.setqflist({}, " ", { title = "Writing: later", items = items })
  vim.cmd("copen")
end

--- Pick the model and effort a task uses for the rest of the session.
--- `arg` "reset" drops every session override.
function M.pick_model(arg)
  local config = require("writing.config")
  if arg == "reset" then
    config.session = {}
    return vim.notify("Model overrides cleared", vim.log.levels.INFO, { title = "Writing" })
  end
  local function show(t)
    local c = config.task(t)
    return ("%-8s %s / %s%s"):format(t, c.model, c.effort, config.session[t] and "  (session)" or "")
  end
  vim.ui.select(config.TASKS, { prompt = "Task", format_item = show }, function(t)
    if not t then return end
    vim.ui.select({ "haiku", "sonnet", "opus", "Custom…" }, { prompt = "Model for " .. t }, function(m)
      if not m then return end
      local function effort(model)
        vim.ui.select({ "low", "medium", "high" }, { prompt = "Effort for " .. t }, function(e)
          if not e then return end
          config.session[t] = { model = model, effort = e }
          vim.notify(("%s: %s / %s for this session"):format(t, model, e), vim.log.levels.INFO, { title = "Writing" })
        end)
      end
      if m == "Custom…" then
        vim.ui.input({ prompt = "Model (alias or full id): " }, function(id)
          if id and id ~= "" then effort(id) end
        end)
      else
        effort(m)
      end
    end)
  end)
end

function M.chat() M.ensure(); require("writing.assist").chat() end

function M.toggle_diagnostics()
  M.ensure()
  local all = { require("writing.grammar").ns_diag, require("writing.conform").ns_diag,
    require("writing.restyle").ns_diag, require("writing.outline").ns_diag, require("writing.rigor").ns_diag }
  local on = not vim.diagnostic.is_enabled({ ns_id = all[1] })
  for _, ns in ipairs(all) do vim.diagnostic.enable(on, { ns_id = ns }) end
  vim.notify("Writing diagnostics " .. (on and "on" or "off"), vim.log.levels.INFO, { title = "Writing" })
end

--- Clear the AI issues (grammar, conform, restyle, rigor, outline flags) of the current buffer.
function M.clear()
  M.ensure()
  require("writing.grammar").clear()
  require("writing.conform").store:clear()
  require("writing.restyle").store:clear()
  require("writing.rigor").store:clear()
  vim.diagnostic.reset(require("writing.outline").ns_diag, 0)
end

return M
