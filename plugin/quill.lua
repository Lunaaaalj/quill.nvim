-- :SpellAudit                       walk every spelling issue
-- :Writing [{sub}] [model=… effort=…]
--                                   grammar (default) | style | paragraph |
--                                   conform | restyle | outline | rigor |
--                                   rewrite | ask | chat | later | needs |
--                                   model | diagnostics | clear
-- :[range]Writing rewrite|ask       on those lines (from visual: the selection)
-- model=/effort= override the configured model for that one run;
-- :Writing model [reset] picks them per task for the session.
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

-- `o` is the command's opts; `a` the run options parsed from model=/effort=.
local subs = {
  grammar = function(_, a) W().grammar(a) end,
  style = function(_, a) W().grammar(vim.tbl_extend("force", a, { style = true })) end,
  paragraph = function(_, a) W().paragraph(a) end,
  conform = function(_, a) W().conform(a) end,
  restyle = function(_, a) W().restyle(a) end,
  outline = function(_, a) W().outline(a) end,
  rigor = function(_, a) W().rigor(a) end,
  rewrite = function(o, a) W().rewrite(target(o), a) end,
  ask = function(o, a) W().ask(target(o), a) end,
  chat = function() W().chat() end,
  later = function() W().later() end,
  needs = function() W().needs() end,
  model = function(o) W().pick_model(o.fargs[2]) end,
  diagnostics = function() W().toggle_diagnostics() end,
  clear = function() W().clear() end,
}

local ARGS = { model = { "haiku", "sonnet", "opus" }, effort = { "low", "medium", "high" } }

-- model=… effort=… after the subcommand; nil + message on anything else.
local function run_args(fargs)
  local a = {}
  for i = 2, #fargs do
    local k, v = fargs[i]:match("^(%a+)=(.+)$")
    if not (k and ARGS[k]) then return nil, "expected model=… or effort=…, got " .. fargs[i] end
    a[k] = v
  end
  return a
end

vim.api.nvim_create_user_command("Writing", function(o)
  local name = o.fargs[1] or "grammar"
  local f = subs[name]
  if not f then return vim.notify("quill: unknown :Writing " .. name, vim.log.levels.ERROR) end
  local a, err = {}, nil
  if name ~= "model" then a, err = run_args(o.fargs) end
  if not a then return vim.notify("quill: " .. err, vim.log.levels.ERROR) end
  f(o, a)
end, {
  nargs = "*",
  range = true,
  desc = "Writing companion (grammar, style, conform, outline, rigor, rewrite, ask, chat, …)",
  complete = function(lead, line)
    local n = #vim.split(line:gsub("^%S*%s*", ""), "%s+")
    local names
    if n <= 1 then
      names = vim.tbl_keys(subs)
    elseif line:match("^%S*%s+model%s") then
      names = { "reset" }
    else
      names = {}
      for k, vs in pairs(ARGS) do
        for _, v in ipairs(vs) do names[#names + 1] = k .. "=" .. v end
      end
    end
    table.sort(names)
    return vim.tbl_filter(function(x) return x:find(lead, 1, true) == 1 end, names)
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
plug("WritingGrammar", function() W().grammar() end, "Writing: grammar audit")
plug("WritingStyle", function() W().grammar({ style = true }) end, "Writing: grammar + style audit")
plug("WritingParagraph", function() W().paragraph() end, "Writing: grammar audit of this paragraph")
plug("WritingConform", function() W().conform() end, "Writing: check against STYLE.md")
plug("WritingRestyle", function() W().restyle() end, "Writing: rewrite paragraphs to follow STYLE.md")
plug("WritingOutline", function() W().outline() end, "Writing: reverse outline")
plug("WritingRigor", function() W().rigor() end, "Writing: rigor review (arguments, claims, evidence)")
plug("WritingRewrite", function() W().rewrite() end, "Writing: rewrite paragraph")
plug("WritingRewrite", visual(function(t) W().rewrite(t) end), "Writing: rewrite selection", "x")
plug("WritingAsk", function() W().ask() end, "Writing: ask about paragraph")
plug("WritingAsk", visual(function(t) W().ask(t) end), "Writing: ask about selection", "x")
plug("WritingChat", subs.chat, "Writing: companion chat")
plug("WritingLater", subs.later, "Writing: list what you left for later")
plug("WritingNeeds", subs.needs, "Writing: list what needs your input")
plug("WritingModel", function() W().pick_model() end, "Writing: pick models for this session")
plug("WritingDiagnostics", subs.diagnostics, "Writing: toggle AI diagnostics")
plug("WritingClear", subs.clear, "Writing: clear AI issues")
