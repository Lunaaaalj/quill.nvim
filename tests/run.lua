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
-- models: setup < session < per run

test("config.task: setup < session override < per-run model/effort", function()
  local c = require("writing.config")
  c.setup({ rigor = { model = "sonnet" } })
  eq(c.task("rigor").model, "sonnet")
  c.session.rigor = { model = "opus", effort = "low" }
  c.setup({}) -- setup() keeps session overrides
  eq(c.task("rigor").model, "opus")
  eq(c.task("rigor", { effort = "high" }).effort, "high")
  eq(c.task("rigor", { effort = "high" }).width, 64, "other options pass through")
  c.session = {}
  eq(c.task("rigor").model, "haiku")
  eq(c.task("conform").model, "sonnet", "conform defaults to a stronger model")
end)

test(":Writing grammar model=… effort=… reaches claude; bad args are rejected", function()
  buf_with({ "A paragraph for the model override test." })
  local seen
  reply = function(o) seen = o; return { issues = {} } end
  vim.cmd("Writing grammar model=opus effort=high")
  eq({ seen.model, seen.effort }, { "opus", "high" })
  local msg
  local notify = vim.notify
  vim.notify = function(m) msg = m end
  vim.cmd("Writing grammar fast")
  vim.notify = notify
  eq(msg, "quill: expected model=… or effort=…, got fast")
  eq(vim.fn.getcompletion("Writing rigor mo", "cmdline"), { "model=haiku", "model=opus", "model=sonnet" })
  eq(vim.fn.getcompletion("Writing model ", "cmdline"), { "reset" })
end)

-- ---------------------------------------------------------------------------
-- STYLE.md

test("prose.profile: STYLE.md over .nvim/writing.md; the nearest directory wins", function()
  local dir = tmp .. "/styleproj"
  vim.fn.mkdir(dir .. "/.nvim", "p")
  vim.fn.mkdir(dir .. "/sub/.nvim", "p")
  vim.fn.writefile({ "root STYLE" }, dir .. "/STYLE.md")
  vim.fn.writefile({ "root legacy" }, dir .. "/.nvim/writing.md")
  local buf = buf_with({ "x" })
  api.nvim_buf_set_name(buf, dir .. "/doc.md")
  eq(prose.profile(buf), "root STYLE", "same directory: STYLE.md first")
  vim.fn.writefile({ "sub legacy" }, dir .. "/sub/.nvim/writing.md")
  local b2 = buf_with({ "x" })
  api.nvim_buf_set_name(b2, dir .. "/sub/doc.md")
  eq(prose.profile(b2), "sub legacy", "a nearer directory wins over the list order")
  require("writing.config").setup({ style_guide = { "GUIDE.md" } })
  eq(prose.profile(buf), nil, "a list option replaces the default list")
  require("writing.config").setup({})
end)

-- ---------------------------------------------------------------------------
-- conform

local conform_dir = tmp .. "/conform"
vim.fn.mkdir(conform_dir, "p")
vim.fn.writefile({ "# House style", "", "- Use the active voice.", "- Write numbers under ten as words." },
  conform_dir .. "/STYLE.md")

local function conform_buf(lines)
  local buf = buf_with(lines)
  api.nvim_buf_set_name(buf, conform_dir .. "/doc" .. buf .. ".md")
  return buf
end

test("conform: no style guide, no request", function()
  local buf = buf_with({ "Some prose without a guide anywhere." })
  api.nvim_buf_set_name(buf, tmp .. "/noguide/doc.md")
  calls = 0
  local msg
  local notify = vim.notify
  vim.notify = function(m) msg = m end
  require("writing.conform").check(buf, {}, function() error("must not finish") end)
  vim.notify = notify
  eq(calls, 0)
  eq(msg:find("No STYLE.md", 1, true) ~= nil, true)
end)

test("conform: invented rules are dropped; accept with 1; cached", function()
  local buf = conform_buf({ "The ball was thrown by the boy, 3 times." })
  calls = 0
  reply = function(o)
    eq(o.model, "sonnet")
    eq(o.prompt:find("Use the active voice.", 1, true) ~= nil, true, "the guide is in the prompt")
    return { issues = {
      { p = 1, quote = "The ball was thrown by the boy", rule = "Use the active voice.", issue = "passive",
        suggestions = { "The boy threw the ball" }, severity = "violation" },
      { p = 1, quote = "3 times", rule = "Never use digits.", issue = "invented rule",
        suggestions = { "three times" }, severity = "violation" },
    } }
  end
  vim.cmd("Writing conform")
  eq(W.current().title, "Conform")
  eq(W.current().remaining, 1, "the finding citing a rule not in the guide is gone")
  eq(W.current().issue.rule, "Use the active voice.")
  keys("1")
  eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], "The boy threw the ball, 3 times.")
  calls = 0
  api.nvim_buf_set_lines(buf, 0, -1, false, { "The ball was thrown by the boy, 3 times." })
  require("writing.conform").check(buf, {}, function() end)
  eq(calls, 0, "unchanged paragraph and guide: served from the cache")
end)

-- ---------------------------------------------------------------------------
-- later

local function two_issues(a, b)
  return function()
    return { issues = {
      { p = 1, quote = a[1], suggestions = { a[2] }, issue = "first", category = "grammar", severity = "error" },
      { p = 1, quote = b[1], suggestions = { b[2] }, issue = "second", category = "grammar", severity = "error" },
    } }
  end
end

test("later: l saves it; the next run walks fresh issues first, then the deferred one", function()
  local buf = buf_with({ "Me and him goes to the park on sundays." })
  reply = two_issues({ "Me and him goes", "He and I go" }, { "sundays", "Sundays" })
  vim.cmd("Writing grammar")
  eq(W.current().issue.text, "Me and him goes")
  keys("l")
  eq(W.current().issue.text, "sundays", "deferred: moved on")
  local key
  for k in pairs(issues.later()) do key = k end
  eq(key ~= nil, true, "saved to later.json")
  keys("s") -- nothing fresh left, and the deferred one is skipped this run: done
  eq(W.current(), nil)

  vim.cmd("Writing grammar")
  eq(W.current().issue.text, "sundays", "fresh first")
  eq(W.current().issue.deferred, false)
  keys("1")
  eq(W.current().issue.text, "Me and him goes", "then the deferred one")
  eq(W.current().issue.deferred, true)
  eq(api.nvim_buf_get_lines(W.current().fbuf, 1, 2, false)[1]:find("· later", 1, true) ~= nil, true)

  keys("q")
  eq(api.nvim_get_current_buf(), buf)
  vim.cmd("Writing later")
  eq(#vim.fn.getqflist(), 1)
  vim.cmd("cclose")

  vim.cmd("Writing grammar")
  keys("1")
  eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], "He and I go to the park on Sundays.")
  eq(W.current(), nil)
  eq(issues.later()[key], nil, "fixing a deferred issue forgets it")
end)

test("later: u takes it back", function()
  buf_with({ "They was here yesterday, wasnt they." })
  reply = two_issues({ "They was", "They were" }, { "wasnt", "weren't" })
  vim.cmd("Writing grammar")
  local n = vim.tbl_count(issues.later())
  keys("l")
  eq(vim.tbl_count(issues.later()), n + 1)
  keys("u")
  eq(vim.tbl_count(issues.later()), n)
  eq(W.current().issue.text, "They was")
  keys("q")
end)

-- ---------------------------------------------------------------------------
-- talk

test("talk: the reply shows, the new suggestion becomes 1, u restores; d still works after", function()
  local buf = buf_with({ "Their going home after the long meeting." })
  local talk_prompt
  reply = function(o)
    if o.schema.properties.reply then
      talk_prompt = o.prompt
      eq(o.model, "sonnet", "talk has its own model")
      return { reply = "Fair: a contraction is less formal.", suggestion = "They are" }
    end
    return { issues = { { p = 1, quote = "Their going", suggestions = { "They're going" }, issue = "homophone",
      category = "grammar", severity = "error" } } }
  end
  local input = vim.ui.input
  vim.ui.input = function(_, cb) cb("no contractions please") end
  vim.cmd("Writing grammar")
  keys("t")
  local S = W.current()
  eq(S.sugg, { "They are", "They're going" })
  eq(talk_prompt:find("Author: no contractions please", 1, true) ~= nil, true)
  local float = table.concat(api.nvim_buf_get_lines(S.fbuf, 0, -1, false), "\n")
  eq(float:find("› Fair: a contraction is less formal.", 1, true) ~= nil, true)
  keys("u")
  eq(W.current().sugg, { "They're going" })
  keys("t")
  keys("d")
  vim.ui.input = input
  eq(W.current(), nil)
  local got
  require("writing.grammar").check(buf, {}, function(n) got = n end)
  eq(got, 0, "dismissed after a talk: stays dismissed")
end)

-- ---------------------------------------------------------------------------
-- facts: what suggestions may not invent

test("facts.invented: numbers, citations, placeholders; number words match digits", function()
  local F = require("writing.facts")
  local doc = "We ran 3 trials with 1,200 people \\cite{smith2020}. See [@doe21]. Mail a@b.com. X-ray, N = 12."
  eq(F.invented("We ran three trials with 1200 people \\cite{smith2020}.", doc), {})
  eq(F.invented("We ran 37 trials, X% of [@roe19].", doc), { "19", "37", "@roe19", "X" })
  eq(F.invented("About [number] people, TBD, XX.", doc), { "TBD", "XX", "[number]" })
  eq(F.invented("The X-ray and N = 12 stay; one of them.", doc), {}, "X-ray, N = and 'one' aren't flagged")
  eq(F.lost("See $a+b$ and \\ref{fig:1} at https://x.org.", "See it at https://x.org."), { "\\ref{fig:1}", "$a+b$" })
end)

test("facts.invented: changing only the decimal or thousands separator invents nothing", function()
  local F = require("writing.facts")
  eq(F.invented("a mean of 3.5 over 1.200 people", "una media de 3,5 sobre 1,200 personas"), {})
  eq(F.invented("una media de 3,5", "a mean of 3.5"), {})
  eq(F.invented("1,234.56 euros", "1.234,56 euros"), {})
  eq(F.invented("1,200,000 cells", "1 200 000 cells"), {}, "space-grouped thousands")
  eq(F.invented("1 200 cells", "1\226\128\175200 cells"), {}, "narrow no-break space")
  eq(F.invented("0.5 s", "0,5 s"), {})
  eq(F.invented("3,6", "3,5"), { "3,6" }, "a different number is still made up")
  eq(F.invented("3.50", "3,5"), { "3.50" }, "an added digit is still made up")
end)

-- (each test uses its own paragraph: answers are cached per paragraph)
local function needs_reply(sugg, needs)
  return function(o)
    if o.schema.properties.reply then
      return { reply = "Thanks, using 37.", suggestion = "37 participants agreed" }
    end
    return { issues = { { p = 1, quote = "participants agreed", rule = "Quantify, don't qualify.",
      issue = "vague quantity", suggestions = sugg, severity = "violation", needs = needs } } }
  end
end

local function quantify_buf(text)
  vim.fn.writefile({ "- Quantify, don't qualify." }, conform_dir .. "/STYLE.md")
  return conform_buf({ text })
end

test("needs input: a made-up number is withheld; flagged, counted, listed; talk resolves it", function()
  local buf = quantify_buf("Many participants agreed with the proposal.")
  reply = needs_reply({ "42 participants agreed" }, "")
  vim.cmd("Writing conform")
  local S = W.current()
  eq(S.title, "Conform")
  eq(S.sugg, {}, "the invented 42 is never offered")
  eq(S.issue.needs ~= nil, true)
  eq(S.needs, 1, "counted in the walker")
  local float = table.concat(api.nvim_buf_get_lines(S.fbuf, 0, -1, false), "\n")
  eq(float:find("needs input", 1, true) ~= nil, true)
  eq(float:find("Needs your input", 1, true) ~= nil, true)
  local d = vim.diagnostic.get(buf, { namespace = require("writing.conform").ns_diag })[1]
  eq({ d.code, d.severity }, { "needs-input", vim.diagnostic.severity.WARN })
  eq(require("writing").counts(buf).needs, 1)

  local input = vim.ui.input
  vim.ui.input = function(_, cb) cb("it was 37 of them") end
  keys("t")
  vim.ui.input = input
  eq(W.current().sugg, { "37 participants agreed" }, "a number the author gave is fine")
  eq(W.current().issue.needs, nil, "resolved")
  keys("u")
  eq(W.current().issue.needs ~= nil, true, "u brings the flag back")
  keys("q")
  api.nvim_set_current_buf(buf)
  vim.cmd("Writing needs")
  eq(#vim.fn.getqflist(), 1)
  vim.cmd("cclose")
end)

test("needs input: the model's own `needs`, and m writes a TODO", function()
  local buf = quantify_buf("Most participants agreed in the end.")
  reply = needs_reply({}, "the number of participants who agreed")
  vim.cmd("Writing conform")
  eq(W.current().issue.needs, "the number of participants who agreed")
  keys("m")
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  eq(lines[2]:find("TODO(style): needs the number of participants who agreed", 1, true) ~= nil, true)
end)

test("talk: a reply that makes up a number keeps it out", function()
  local buf = quantify_buf("Several participants agreed later.")
  reply = function(o)
    if o.schema.properties.reply then return { reply = "Sure.", suggestion = "99 participants agreed" } end
    return needs_reply({}, "how many agreed")(o)
  end
  vim.cmd("Writing conform")
  local input = vim.ui.input
  vim.ui.input = function(_, cb) cb("make it concrete") end
  keys("t")
  vim.ui.input = input
  eq(W.current().sugg, {})
  local float = table.concat(api.nvim_buf_get_lines(W.current().fbuf, 0, -1, false), "\n")
  eq(float:find("withheld: it made up 99", 1, true) ~= nil, true)
  keys("q")
  eq(buf ~= nil, true)
end)

-- ---------------------------------------------------------------------------
-- restyle

test("restyle: paragraph rewrites walked as a diff; invented rules and lost markup dropped", function()
  vim.fn.writefile({ "- Use the active voice.", "- Write numbers under ten as words." }, conform_dir .. "/STYLE.md")
  local buf = conform_buf({
    "The ball was thrown by the boy 3 times.", "",
    "The cat was fed by me \\cite{key1}.", "",
    "Results were obtained by the team.", "",
    "This one is fine.",
  })
  calls = 0
  reply = function(o)
    eq(o.model, "sonnet")
    return { paragraphs = {
      { p = 1, rewrite = "The boy threw the ball three times.", needs = "", changes = {
        { rule = "Use the active voice.", change = "active voice" },
        { rule = "Write numbers under ten as words.", change = "3 -> three" } } },
      { p = 2, rewrite = "I fed the cat.", needs = "", changes = {
        { rule = "Use the active voice.", change = "active voice" } } },
      { p = 3, rewrite = "The team obtained results.", needs = "", changes = {
        { rule = "Never start with 'The'.", change = "invented" } } },
    } }
  end
  vim.cmd("Writing restyle")
  local S = W.current()
  eq(S.title, "Restyle")
  eq(S.remaining, 1, "p2 lost its citation, p3 cited an invented rule")
  local float = api.nvim_buf_get_lines(S.fbuf, 0, -1, false)
  eq(float[1], " 2 changes")
  local marks = api.nvim_buf_get_extmarks(S.fbuf, -1, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do groups[m[4].hl_group] = true end
  eq(groups.WritingDel and groups.WritingAdd, true, "the diff is highlighted")
  keys("1")
  eq(api.nvim_buf_get_lines(buf, 0, 1, false)[1], "The boy threw the ball three times.")
  eq(W.current(), nil)
  calls = 0
  api.nvim_buf_set_lines(buf, 0, 1, false, { "The ball was thrown by the boy 3 times." })
  require("writing.restyle").check(buf, {}, function() end)
  eq(calls, 0, "served from the cache (unchanged paragraphs too)")
end)

test("walker: the float never covers the paragraph it shows", function()
  vim.fn.writefile({ "- Use the active voice." }, conform_dir .. "/STYLE.md")
  local lines = {}
  for i = 1, 40 do lines[#lines + 1] = "Filler line " .. i .. "." end
  local para = { "The ball was thrown by the boy.", "The cake was eaten by the girl.",
    "The song was sung by the choir.", "The car was driven by the man." }
  vim.list_extend(lines, { "" })
  vim.list_extend(lines, para)
  conform_buf(lines)
  local win = api.nvim_get_current_win()
  api.nvim_win_set_cursor(win, { 1, 0 })
  -- the filler is one paragraph, ours the next: answer only for ours
  reply = function(o)
    local ps = {}
    for p in o.prompt:gmatch("%[p(%d+)%]\nThe ball") do
      ps[1] = { p = tonumber(p), needs = "", changes = { { rule = "Use the active voice.", change = "active voice" } },
        rewrite = "The boy threw the ball.\nThe girl ate the cake.\nThe choir sang the song.\nThe man drove the car." }
    end
    return { paragraphs = ps }
  end
  vim.cmd("Writing restyle")
  local S = W.current()
  eq(S.title, "Restyle")
  local cfg = api.nvim_win_get_config(S.float)
  local wtop = vim.fn.win_screenpos(win)[1]
  local top = vim.fn.screenpos(win, 42, 1).row - wtop + 1
  local bottom = vim.fn.screenpos(win, 45, 1).row - wtop + 1
  eq(top > 0 and bottom > 0, true, "the whole paragraph is on screen")
  local rows = cfg.height + 2
  local first = cfg.anchor == "NW" and cfg.row + 1 or cfg.row - rows + 1 -- 1-based window lines
  local last = first + rows - 1
  eq(last < top or first > bottom, true, ("float %d-%d overlaps the paragraph %d-%d"):format(first, last, top, bottom))
  keys("q")
end)

test("restyle: a rewrite that makes up a figure is withheld and needs input", function()
  vim.fn.writefile({ "- Quantify, don't qualify." }, conform_dir .. "/STYLE.md")
  local buf = conform_buf({ "Many people came to the event." })
  reply = function()
    return { paragraphs = { { p = 1, rewrite = "About 250 people came to the event.", needs = "",
      changes = { { rule = "Quantify, don't qualify.", change = "a number" } } } } }
  end
  vim.cmd("Writing restyle")
  eq(W.current().sugg, {})
  eq(W.current().issue.needs:find("250", 1, true) ~= nil, true)
  keys("q")
  eq(require("writing").counts(buf).needs, 1)
end)

-- ---------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(passed, #failed))
for _, f in ipairs(failed) do io.write("\nFAIL " .. f .. "\n") end
vim.cmd(#failed == 0 and "qall!" or "cquit!")
