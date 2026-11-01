-- quill.nvim: a proofreading kit. A spell audit that walks every spelling
-- issue (offline), and Claude (a cheap model, through the `claude` CLI and
-- your Claude Code login) as copy editor, developmental editor and reader.
--
--   spell       walk every spelling issue (]s + spellbadword) in a float
--   grammar     grammar audit (+ style), walked like the spell audit;
--               issues are also diagnostics
--   outline     reverse outline: summary, role and flags per paragraph
--   rigor       peer review: loose arguments, unsupported or overclaimed
--               statements, fallacies, inconsistencies (report + walk)
--   rewrite/ask on the selection or the paragraph under the cursor
--   chat        companion chat in a split
--
-- Nothing runs on its own: text only leaves Neovim when you ask. Results are
-- cached, so repeating a pass only sends what changed. Modules: claude.lua
-- (CLI), prose.lua (paragraphs), issues.lua (quote-anchored findings),
-- walker.lua (the audit float), spell.lua, grammar.lua, rigor.lua,
-- outline.lua, assist.lua. Commands and <Plug> maps: plugin/quill.lua.

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

function M.outline() M.ensure(); require("writing.outline").open() end

function M.rigor() M.ensure(); require("writing.rigor").review() end

--- Rewrite / ask: `target` true = the last visual selection, { r1, r2 } = those
--- lines (1-based), nil = the paragraph under the cursor.
function M.rewrite(target) M.ensure(); require("writing.assist").rewrite(target) end

function M.ask(target) M.ensure(); require("writing.assist").ask(target) end

function M.chat() M.ensure(); require("writing.assist").chat() end

function M.toggle_diagnostics()
  M.ensure()
  local all = { require("writing.grammar").ns_diag, require("writing.outline").ns_diag, require("writing.rigor").ns_diag }
  local on = not vim.diagnostic.is_enabled({ ns_id = all[1] })
  for _, ns in ipairs(all) do vim.diagnostic.enable(on, { ns_id = ns }) end
  vim.notify("Writing diagnostics " .. (on and "on" or "off"), vim.log.levels.INFO, { title = "Writing" })
end

--- Clear the AI issues (grammar, rigor, outline flags) of the current buffer.
function M.clear()
  M.ensure()
  require("writing.grammar").clear()
  require("writing.rigor").store:clear()
  vim.diagnostic.reset(require("writing.outline").ns_diag, 0)
end

return M
