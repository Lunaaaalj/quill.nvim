-- Headless test suite. Run with `make test` (or the command in the Makefile).
-- No dependencies: a tiny test()/eq() helper, `claude.run` stubbed, and the
-- XDG dirs pointed at a temp dir so caches, dismissals and the spellfile
-- never touch your real state.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/quill.lua")
vim.o.swapfile = false
vim.g.mapleader = " "

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/spell", "p")
vim.o.spellfile = tmp .. "/spell/en.utf-8.add"
vim.o.spelllang = "en"

local api = vim.api
local passed, failed = 0, {}

local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(("%s\n  expected: %s\n  got:      %s"):format(msg or "not equal", vim.inspect(b), vim.inspect(a)), 2)
  end
end

local function test(name, fn)
  vim.cmd("silent! %bwipeout!")
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failed[#failed + 1] = name .. "\n" .. err
  end
end

local function buf_with(lines, ft)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "markdown"
  return buf
end

-- Feed keys and process them now ("x": execute, so mappings run).
local function keys(k) api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false) end

-- claude.run stub: answers from `reply(o)`, counting calls.
local claude = require("writing.claude")
local calls = 0
local reply = function() return {} end
claude.run = function(o, cb)
  calls = calls + 1
  cb(nil, reply(o))
end

require("writing").setup({})
vim.notify = function() end

-- ---------------------------------------------------------------------------
-- config

test("config: deep merge, lists replace", function()
  local c = require("writing.config")
  c.setup({ grammar = { model = "sonnet" }, assist = { presets = { "Only this" } } })
  eq(c.options.grammar.model, "sonnet")
  eq(c.options.grammar.effort, "low", "unset keys keep their default")
  eq(c.options.assist.presets, { "Only this" })
  c.setup({})
  eq(c.options.grammar.model, "haiku")
end)

test("highlights: default links, overrides (table or function) win", function()
  local hl = require("writing.hl")
  hl.apply()
  eq(api.nvim_get_hl(0, { name = "SpellAuditMuted" }).link, "Comment")
  require("writing.config").setup({ highlights = function() return { SpellAuditMuted = { fg = 0x123456 } } end })
  hl.apply()
  eq(api.nvim_get_hl(0, { name = "SpellAuditMuted" }).fg, 0x123456)
  require("writing.config").setup({})
end)

test("hint: the key mapped to a <Plug>, else the fallback", function()
  local W = require("writing")
  eq(W.hint("<Plug>(SpellAudit)", ":SpellAudit"), ":SpellAudit")
  vim.keymap.set("n", "<leader>sa", "<Plug>(SpellAudit)")
  eq(W.hint("<Plug>(SpellAudit)", ":SpellAudit"), "<leader>sa")
  vim.keymap.del("n", "<leader>sa")
end)

-- ---------------------------------------------------------------------------
-- prose

local prose = require("writing.prose")

local function texts(paras)
  return vim.tbl_map(function(p) return p.text end, paras)
end

test("prose: markdown skips front matter, fences and comments", function()
  local buf = buf_with({
    "---", "title: x", "---", "",
    "# A heading here", "",
    "This is the first real paragraph", "that spans two lines.", "",
    "```lua", "local not_prose = true", "```", "",
    "<!--", "a comment with words in it", "-->", "",
    "Second paragraph of plain prose.",
  })
  local paras = prose.paragraphs(buf)
  eq(texts(paras), {
    "# A heading here",
    "This is the first real paragraph\nthat spans two lines.",
    "Second paragraph of plain prose.",
  })
  eq({ paras[2].srow, paras[2].erow }, { 7, 8 })
end)

test("prose: LaTeX skips preamble, math, comments; keeps \\section", function()
  local buf = buf_with({
    "\\documentclass{article}", "\\usepackage{amsmath}", "\\begin{document}",
    "\\section{Intro}",
    "Some words of real prose here.",
    "% a comment with several words in it",
    "\\begin{equation}", "a = b + c and more words", "\\end{equation}",
    "\\label{sec:intro}",
    "",
    "More prose after the math block.",
    "\\end{document}",
  }, "tex")
  eq(texts(prose.paragraphs(buf)), {
    "\\section{Intro}",
    "Some words of real prose here.",
    "More prose after the math block.",
  })
end)

test("prose: Typst skips #set/#let, raw blocks and display math", function()
  local buf = buf_with({
    "#set page(width: 10cm)", "#let x = 1", "",
    "= Heading",
    "Prose in typst with words.", "",
    "$", "x = y and words", "$", "",
    "```", "raw block with words here", "```",
    "Last bit of prose here.",
  }, "typst")
  eq(texts(prose.paragraphs(buf)), { "= Heading", "Prose in typst with words.", "Last bit of prose here." })
end)

test("prose.locate: collapses whitespace across lines; `from` finds later hits", function()
  local p = { srow = 10, erow = 11, lines = { "the cat sat on", "the  mat with the cat" } }
  p.text = table.concat(p.lines, "\n")
  local r1, c1, r2, c2 = prose.locate(p, "on the mat")
  eq({ r1, c1, r2, c2 }, { 10, 12, 11, 8 })
  local a = { prose.locate(p, "the cat") }
  eq({ a[1], a[2] }, { 10, 0 })
  local b = { prose.locate(p, "the cat", a[5]) }
  eq({ b[1], b[2], b[3], b[4] }, { 11, 14, 11, 21 })
  eq(prose.locate(p, "not there"), nil)
end)

test("prose.profile: style_guide path, function, false", function()
  local dir = tmp .. "/proj"
  vim.fn.mkdir(dir .. "/.nvim", "p")
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.writefile({ "Use British spelling." }, dir .. "/.nvim/writing.md")
  local buf = buf_with({ "x" })
  api.nvim_buf_set_name(buf, dir .. "/sub/doc.md")
  local text, path = prose.profile(buf)
  eq(text, "Use British spelling.")
  eq(vim.fn.resolve(path), vim.fn.resolve(dir .. "/.nvim/writing.md"))
  require("writing.config").setup({ style_guide = false })
  eq(prose.profile(buf), nil)
  require("writing.config").setup({ style_guide = function() return "inline", nil end })
  eq(prose.profile(buf), "inline")
  require("writing.config").setup({})
end)

-- ---------------------------------------------------------------------------
-- issue store

local issues = require("writing.issues")
local n_store = 0
local function new_store(o)
  n_store = n_store + 1
  return issues.store("test" .. n_store, vim.tbl_extend("force", {
    source = "test", severity = {}, overlap = false, need_fix = true,
    label = function(f) return f.category or "" end,
    note = function(f) return f.issue or "" end,
    message = function(f) return f.issue or "" end,
  }, o or {}))
end

test("store: drops hallucinated quotes, overlaps, no-op fixes", function()
  local buf = buf_with({ "Their is a error in this sentense here." })
  local paras = prose.paragraphs(buf)
  local s = new_store()
  local n = s:anchor(buf, paras, { [1] = {
    { quote = "Their is", suggestions = { "There is" }, issue = "a" },
    { quote = "is a", suggestions = { "is an" }, issue = "overlaps the first" },
    { quote = "a error", suggestions = { "an error" }, issue = "b" },
    { quote = "not in the text", suggestions = { "x" }, issue = "hallucinated" },
    { quote = "sentense", suggestions = { "sentense" }, issue = "no-op suggestion" },
  } })
  eq(n, 2)
  eq(vim.tbl_map(function(it) return it.text end, s:items(buf)), { "Their is", "a error" })
  eq(#vim.diagnostic.get(buf, { namespace = s.ns_diag }), 2)
end)

test("store: overlap = true keeps overlaps but not exact duplicates", function()
  local buf = buf_with({ "All swans are white, so this proves it." })
  local s = new_store({ overlap = true, need_fix = false })
  local n = s:anchor(buf, prose.paragraphs(buf), { [1] = {
    { quote = "All swans are white", suggestions = {}, issue = "overclaim" },
    { quote = "swans are white", suggestions = {}, issue = "unsupported" },
    { quote = "swans are white", suggestions = {}, issue = "unsupported" },
  } })
  eq(n, 2)
end)

test("store: a fixed issue vanishes and undo brings it back", function()
  local buf = buf_with({ "This has a error in it, sadly." })
  local s = new_store()
  s:anchor(buf, prose.paragraphs(buf), { [1] = { { quote = "a error", suggestions = { "an error" }, issue = "x" } } })
  eq(#s:items(buf), 1)
  local it = s:items(buf)[1]
  vim.cmd("let &l:undolevels = &l:undolevels")
  api.nvim_buf_set_text(buf, it.row - 1, it.col, it.end_row - 1, it.end_col, { "an error" })
  eq(#s:items(buf), 0)
  vim.cmd("silent undo")
  eq(#s:items(buf), 1)
end)

test("store: issues move with edits above them", function()
  local buf = buf_with({ "Here is a error in prose text." })
  local s = new_store()
  s:anchor(buf, prose.paragraphs(buf), { [1] = { { quote = "a error", suggestions = { "an error" }, issue = "x" } } })
  api.nvim_buf_set_lines(buf, 0, 0, false, { "New first line.", "" })
  eq(s:items(buf)[1].row, 3)
end)

-- ---------------------------------------------------------------------------
-- walker (through the spell audit, which needs no Claude)

local W = require("writing.walker")

local function spell_buf()
  local buf = buf_with({ "This sentense has a mistaek in it." }, "text")
  vim.wo.spell = true
  return buf
end

test("spell audit: finds issues the way ]s does", function()
  spell_buf()
  vim.cmd("SpellAudit")
  local S = W.current()
  eq(S.remaining, 2)
  eq(S.issue.text, "sentense")
  keys("q")
end)

test("<Plug>(SpellAudit) through a recursive key map starts the audit", function()
  spell_buf()
  vim.keymap.set("n", "<leader>sa", "<Plug>(SpellAudit)", { remap = true })
  keys(" sa")
  vim.keymap.del("n", "<leader>sa")
  eq(W.current() and W.current().issue.text, "sentense")
  keys("q")
end)

test("walker: 1 fixes, u undoes exactly that fix", function()
  local buf = spell_buf()
  vim.cmd("SpellAudit")
  local S = W.current()
  local first = S.sugg[1]
  keys("1")
  eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find(first, 1, true) ~= nil, true, "fix applied")
  eq(W.current().issue.text, "mistaek")
  keys("1")
  keys("u")
  local line = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  eq(line:find("mistaek", 1, true) ~= nil, true, "second fix undone")
  eq(line:find(first, 1, true) ~= nil, true, "first fix kept")
  keys("q")
end)

test("walker: s skips, q pauses, starting again resumes", function()
  spell_buf()
  vim.cmd("SpellAudit")
  keys("s")
  eq(W.current().issue.text, "mistaek")
  keys("q")
  eq(W.current().paused, true)
  vim.cmd("SpellAudit")
  eq(W.current().paused, false)
  eq(W.current().issue.text, "mistaek", "the skip survives the pause")
  keys("q")
end)

test("spell audit: a adds to the spellfile, u removes it", function()
  spell_buf()
  vim.cmd("SpellAudit")
  keys("a")
  local words = vim.fn.readfile(vim.o.spellfile)
  eq(vim.tbl_contains(words, "sentense"), true)
  keys("u")
  eq(vim.tbl_contains(vim.fn.readfile(vim.o.spellfile), "sentense"), false)
  keys("q")
end)

-- ---------------------------------------------------------------------------
-- grammar, with claude.run stubbed

test("grammar: anchors answers, caches per paragraph", function()
  local buf = buf_with({ "The results is clear and simple.", "", "Another paragraph without errors here." })
  calls = 0
  reply = function(o)
    eq(o.schema ~= nil, true, "asks for structured output")
    return { issues = { { p = 1, quote = "results is", suggestions = { "results are" }, issue = "agreement",
      category = "grammar", severity = "error" } } }
  end
  local got
  require("writing.grammar").check(buf, {}, function(n) got = n end)
  eq(got, 1)
  eq(calls, 1)
  require("writing.grammar").check(buf, {}, function(n) got = n end)
  eq(calls, 1, "second run is served from the cache")
  eq(got, 1)
  eq(vim.diagnostic.get(buf, { namespace = require("writing.grammar").ns_diag })[1].source, "claude")
end)

test("grammar audit: walk, fix with 1", function()
  local buf = buf_with({ "She go to school every single day." })
  reply = function()
    return { issues = { { p = 1, quote = "She go", suggestions = { "She goes" }, issue = "agreement",
      category = "grammar", severity = "error" } } }
  end
  vim.cmd("Writing grammar")
  eq(W.current().title, "Grammar")
  keys("1")
  eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], "She goes to school every single day.")
end)

test(":Writing rejects unknown subcommands, completes known ones", function()
  local msg
  local notify = vim.notify
  vim.notify = function(m) msg = m end
  vim.cmd("Writing nope")
  vim.notify = notify
  eq(msg, "quill: unknown :Writing nope")
  eq(vim.fn.getcompletion("Writing ri", "cmdline"), { "rigor" })
end)

-- ---------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(passed, #failed))
for _, f in ipairs(failed) do io.write("\nFAIL " .. f .. "\n") end
vim.cmd(#failed == 0 and "qall!" or "cquit!")
