-- STYLE.md conformance: your style guide as a rulebook. The paragraphs go to
-- Claude with the guide, and every finding cites the rule it breaks, copied
-- verbatim from the guide, with a rewrite of the passage. Findings are walked
-- with the shared walker:
--
--   1-4 / <CR>   accept that rewrite          e   edit it yourself
--   t            talk about it: ask why, push back, ask for another kind of
--                change, or give the facts it needs; the reply shows in the
--                float and a new rewrite becomes 1
--   m            insert a TODO(style) comment under the passage
--   s skip · l leave for later · d reject for good · u undo · q pause
--
--   * Rules like "quantify, don't qualify" need facts only you have. The
--     model is told not to invent them, and a rewrite that still brings in a
--     number, citation or placeholder the document doesn't have is withheld
--     (facts.lua): the finding stays, marked "needs input" (see issues.lua).
--
--   * A finding whose quote isn't in its paragraph, or whose rule isn't in
--     the guide, is dropped: that's how hallucinated findings and invented
--     rules die.
--   * Results are cached per paragraph (its text, the model, the language,
--     the glossary and the guide), so re-running after an edit only sends the
--     paragraphs that changed, and editing the guide re-checks everything.
--   * Findings are also diagnostics (source "conform").

local prose = require("writing.prose")
local claude = require("writing.claude")
local issues = require("writing.issues")
local W = require("writing.walker")

local M = {}

local function task(o) return require("writing.config").task("conform", o) end

local api = vim.api
local bufnr = issues.bufnr
local norm = issues.norm

local SCHEMA = {
  type = "object",
  properties = {
    issues = {
      type = "array",
      items = {
        type = "object",
        properties = {
          p = { type = "integer", description = "paragraph number" },
          quote = { type = "string" },
          rule = { type = "string" },
          issue = { type = "string" },
          suggestions = { type = "array", items = { type = "string" } },
          severity = { type = "string", enum = { "violation", "suggestion" } },
          needs = { type = "string" },
        },
        required = { "p", "quote", "rule", "issue", "suggestions", "severity", "needs" },
        additionalProperties = false,
      },
    },
  },
  required = { "issues" },
  additionalProperties = false,
}

local SYSTEM = [[
You check a writer's prose against their style guide. The guide is the only standard: report a passage only when it goes against one of the guide's rules. Do not report grammar, spelling or taste the guide doesn't cover.

Rules:
- rule: the guide's rule that the passage breaks, copied verbatim from the guide: the shortest exact span that states it (usually one sentence or list item). Never paraphrase or combine rules.
- quote: the shortest exact span of the paragraph that breaks the rule, copied verbatim with any markup, usually a clause or a sentence. Findings must not overlap; if a span breaks several rules, report the most important one.
- suggestions: one to three replacements for exactly the quoted span that follow the rule, best first, keeping its meaning, markup, citations and language.
- issue: how the passage breaks the rule, in under twenty words, in the paragraph's language.
- severity: violation when the guide states the rule as a requirement, suggestion when it is a preference.
- Never invent facts. Suggestions may not add any number, date, name, quantity or citation that isn't already in the document, and never placeholders like X, N or [number]. When following the rule needs information only the author has (a figure, a source, a name), give no suggestions and say in needs exactly what the author must supply ("the number of participants"). Otherwise needs is "".
- p: the paragraph's number.
- The source is LaTeX, Typst or Markdown. Never touch commands, math, code, citations, labels, references or URLs.
- Text that follows the guide gets no finding. Returning no issues is a good answer.]]

local SEV = { violation = vim.diagnostic.severity.WARN, suggestion = vim.diagnostic.severity.HINT }

local function short(s, n)
  s = norm(s)
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

local store = issues.store("conform", {
  source = "conform", severity = SEV, overlap = false, need_fix = true,
  label = function(f) return f.severity .. " · " .. short(f.rule, 50) end,
  note = function(f) return f.issue .. "\nRule: " .. f.rule end,
  message = function(f) return f.issue .. " (" .. short(f.rule, 60) .. ")" end,
})
M.store = store
M.ns_diag = store.ns_diag

local cache
local function get_cache()
  cache = cache or issues.load(issues.json_file("cache", "conform.json"))
  return cache
end

local function save_cache()
  local keys = vim.tbl_keys(cache)
  if #keys > 3000 then
    table.sort(keys, function(a, b) return (cache[a].t or 0) > (cache[b].t or 0) end)
    for i = 3001, #keys do cache[keys[i]] = nil end
  end
  issues.save(issues.json_file("cache", "conform.json"), cache)
end

--- Findings whose rule is really in the guide (whitespace-insensitive).
function M.verified(found, guide)
  local g = norm(guide)
  return vim.tbl_filter(function(f)
    return type(f.rule) == "string" and norm(f.rule) ~= "" and g:find(norm(f.rule), 1, true) ~= nil
  end, found or {})
end

local function anchor(buf, paras, keys, guide)
  local by = {}
  for _, p in ipairs(paras) do
    local entry = cache[keys[p.id]]
    -- the severity rides in `severity`, the rule in `rule`; category for diagnostics
    by[p.id] = vim.tbl_map(function(f)
      return vim.tbl_extend("force", f, { category = "conform" })
    end, M.verified(vim.deepcopy(entry and entry.issues or {}), guide))
  end
  return store:anchor(buf, paras, by)
end

local function para_key(p, ctx)
  return vim.fn.sha256(table.concat({ ctx.c.model, ctx.c.effort, ctx.lang, vim.fn.sha256(ctx.guide),
    table.concat(ctx.glossary, ","), p.text }, "\31"))
end

local function prompt_for(batch, ctx)
  local parts = {
    "Language: " .. ctx.lang .. ".",
    "\nThe style guide:\n<style_guide>\n" .. ctx.guide .. "\n</style_guide>",
  }
  if #ctx.glossary > 0 then
    parts[#parts + 1] = "\nCorrect as written, never report: " .. table.concat(ctx.glossary, ", ")
  end
  parts[#parts + 1] = "\nParagraphs:\n"
  for _, p in ipairs(batch) do parts[#parts + 1] = ("[p%d]\n%s\n"):format(p.id, p.text) end
  return table.concat(parts, "\n")
end

--- Check `buf` against its style guide. `o.range` = { s, e } rows,
--- `o.model` / `o.effort` override the configured ones; cb(n) when done.
function M.check(buf, o, cb)
  buf, o = bufnr(buf), o or {}
  local guide, path = prose.profile(buf)
  if not guide or vim.trim(guide) == "" then
    return vim.notify("No STYLE.md found above this file (see :help quill-style-guide)", vim.log.levels.ERROR,
      { title = "Conform" })
  end
  local paras = prose.paragraphs(buf)
  if o.range then
    paras = vim.tbl_filter(function(p) return p.erow >= o.range[1] and p.srow <= o.range[2] end, paras)
  end
  if #paras == 0 then
    return vim.notify("No prose to check here", vim.log.levels.WARN, { title = "Conform" })
  end
  local c = task(o)
  local ctx = { lang = prose.language(buf), guide = guide, glossary = prose.glossary(buf), c = c }
  get_cache()

  local keys, todo = {}, {}
  for _, p in ipairs(paras) do
    keys[p.id] = para_key(p, ctx)
    if not cache[keys[p.id]] then todo[#todo + 1] = p end
  end

  local batches, cur, size = {}, {}, 0
  for _, p in ipairs(todo) do
    if size > 0 and size + #p.text > c.chunk_chars then
      batches[#batches + 1], cur, size = cur, {}, 0
    end
    cur[#cur + 1] = p
    size = size + #p.text
  end
  if #cur > 0 then batches[#batches + 1] = cur end

  local tick = api.nvim_buf_get_changedtick(buf)
  local function finish(errs)
    if not api.nvim_buf_is_valid(buf) then return end
    if api.nvim_buf_get_changedtick(buf) ~= tick then
      paras = vim.tbl_filter(function(p) return cache[para_key(p, ctx)] end, prose.paragraphs(buf))
      for _, p in ipairs(paras) do keys[p.id] = para_key(p, ctx) end
    end
    local n = anchor(buf, paras, keys, guide)
    local msg = ("%d finding%s against %s"):format(n, n == 1 and "" or "s", vim.fn.fnamemodify(path or "the guide", ":~:."))
    local needs = #vim.tbl_filter(function(it) return it.needs ~= nil end, store:items(buf))
    if needs > 0 then msg = msg .. (", %d need%s your input"):format(needs, needs == 1 and "s" or "") end
    if #batches > 0 then msg = msg .. (" (%d new, %d cached)"):format(#todo, #paras - #todo) end
    if #errs > 0 then msg = msg .. "\n" .. table.concat(errs, "\n") end
    vim.notify(msg, #errs > 0 and vim.log.levels.WARN or vim.log.levels.INFO, { title = "Conform" })
    if cb then cb(n) end
  end

  if #batches == 0 then return finish({}) end
  vim.notify(("Checking %d paragraph%s against the style guide with %s…"):format(#todo, #todo == 1 and "" or "s",
    c.model), vim.log.levels.INFO, { title = "Conform" })
  local pending, errs = #batches, {}
  for _, batch in ipairs(batches) do
    claude.run({
      prompt = prompt_for(batch, ctx), system = SYSTEM, schema = SCHEMA,
      model = c.model, effort = c.effort,
    }, function(err, res)
      if err then
        errs[#errs + 1] = err
      else
        local by = {}
        for _, iss in ipairs(res.issues or {}) do
          by[iss.p] = by[iss.p] or {}
          table.insert(by[iss.p], iss)
        end
        local now = os.time()
        for _, p in ipairs(batch) do cache[keys[p.id]] = { issues = by[p.id] or {}, t = now } end
      end
      pending = pending - 1
      if pending == 0 then
        save_cache()
        finish(errs)
      end
    end)
  end
end

M.todo = store:todo_action("style", function(it)
  return (it.needs and ("needs " .. it.needs .. ". ") or "") .. it.issue .. " (" .. short(it.rule, 60) .. ")"
end)

function M.walk(buf, win)
  buf = bufnr(buf)
  W.start({
    key = "conform:" .. buf, title = "Conform", win = win,
    issues = function(S) return store:items(S.buf) end, later_key = store.later_key,
    keys = {
      { "d", "reject for good", store:dismiss_action() },
      { "t", "talk about it", store:talk_action() },
      { "m", "insert a TODO comment", M.todo },
    },
    order = { "fixed", "discussed", "marked", "skipped", "later", "dismissed" },
    footer = " 1-4 accept · e edit · t talk · m TODO · s skip · l later · d reject · u undo · q quit ",
    empty = "Nothing against the style guide",
    resume_hint = require("writing").hint("<Plug>(WritingConform)", ":Writing conform"),
    on_finish = function(S) store:refresh(S.buf) end,
  })
end

--- Check (cached paragraphs are instant) and walk the findings.
function M.audit(o)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local cur = W.current()
  if cur and cur.key == "conform:" .. buf and cur.paused then return M.walk(buf, win) end
  M.check(buf, o, function(n)
    if n > 0 and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then M.walk(buf, win) end
  end)
end

return M
