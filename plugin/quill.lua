-- :SpellAudit                       walk every spelling issue
-- :Writing [{sub}]                  grammar (default) | style | paragraph |
--                                   outline | rigor | rewrite | ask | chat |
--                                   diagnostics | clear
-- :[range]Writing rewrite|ask       on those lines (from visual: the selection)
-- <Plug>(…) maps for all of them; no keys are bound. Nothing else runs at
-- startup: autocmds are set up by setup() or on first use.

if vim.g.loaded_quill then return end
vim.g.loaded_quill = true

local function W() return require("writing") end

-- A command range: the visual selection when it came from one, else the lines.
local function target(o)
  if o.range == 0 then return nil end
  local s, e = vim.fn.line("'<"), vim.fn.line("'>")
  if s == o.line1 and e == o.line2 then return true end
  return { o.line1, o.line2 }
end

local subs = {
  grammar = function() W().grammar() end,
  style = function() W().grammar({ style = true }) end,
  paragraph = function() W().paragraph() end,
  outline = function() W().outline() end,
  rigor = function() W().rigor() end,
  rewrite = function(o) W().rewrite(target(o)) end,
  ask = function(o) W().ask(target(o)) end,
  chat = function() W().chat() end,
  diagnostics = function() W().toggle_diagnostics() end,
  clear = function() W().clear() end,
}

vim.api.nvim_create_user_command("Writing", function(o)
  local name = o.fargs[1] or "grammar"
  local f = subs[name]
  if not f then return vim.notify("quill: unknown :Writing " .. name, vim.log.levels.ERROR) end
  f(o)
end, {
  nargs = "?",
  range = true,
  desc = "Writing companion (grammar, style, outline, rigor, rewrite, ask, chat, …)",
  complete = function(lead)
    local names = vim.tbl_keys(subs)
    table.sort(names)
    return vim.tbl_filter(function(n) return n:find(lead, 1, true) == 1 end, names)
  end,
})

vim.api.nvim_create_user_command("SpellAudit", function() W().spell() end,
  { desc = "Walk every spelling issue in the buffer" })

-- <Plug> maps. In visual mode, leave it first so '< '> are set.
local function plug(name, fn, desc, modes)
  vim.keymap.set(modes or "n", "<Plug>(" .. name .. ")", fn, { desc = desc })
end
local function visual(fn)
  return function()
    vim.cmd("normal! \27")
    fn(true)
  end
end

plug("SpellAudit", function() W().spell() end, "Spell audit (walk every issue)")
plug("WritingGrammar", subs.grammar, "Writing: grammar audit")
plug("WritingStyle", subs.style, "Writing: grammar + style audit")
plug("WritingParagraph", subs.paragraph, "Writing: grammar audit of this paragraph")
plug("WritingOutline", subs.outline, "Writing: reverse outline")
plug("WritingRigor", subs.rigor, "Writing: rigor review (arguments, claims, evidence)")
plug("WritingRewrite", function() W().rewrite() end, "Writing: rewrite paragraph")
plug("WritingRewrite", visual(function(t) W().rewrite(t) end), "Writing: rewrite selection", "x")
plug("WritingAsk", function() W().ask() end, "Writing: ask about paragraph")
plug("WritingAsk", visual(function(t) W().ask(t) end), "Writing: ask about selection", "x")
plug("WritingChat", subs.chat, "Writing: companion chat")
plug("WritingDiagnostics", subs.diagnostics, "Writing: toggle AI diagnostics")
plug("WritingClear", subs.clear, "Writing: clear AI issues")
