-- Grammar audit with Claude: the buffer's paragraphs go to a cheap model in a
-- few batched requests, issues come back as verbatim quotes + replacements,
-- and they become extmark-anchored issues you walk with the shared audit
-- walker (and diagnostics, for ]d / Trouble / signs).
--
--   * Results are cached per paragraph (its text, the model, the mode, the
--     language and your style guide), so re-running after an edit only sends
--     the paragraphs that changed.
--   * A quote that isn't in its paragraph is dropped (that's how hallucinated
--     issues die), and so is one overlapping an earlier issue.
--   * Issues are extmarks: they move with your edits, and one whose text no
--     longer matches its quote (you fixed it) disappears.
--   * `d` in the walker dismisses an issue for good (stdpath("state")), `l`
--     leaves it for later, `t` talks about it (a new suggestion becomes 1).

local prose = require("writing.prose")
local claude = require("writing.claude")
local issues = require("writing.issues")
local W = require("writing.walker")

local M = {}

local function task(o) return require("writing.config").task("grammar", o) end

local api = vim.api
local bufnr = issues.bufnr

local CATEGORIES = { "grammar", "spelling", "punctuation", "word-choice", "style", "clarity" }

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
          suggestions = { type = "array", items = { type = "string" } },
          issue = { type = "string" },
          category = { type = "string", enum = CATEGORIES },
          severity = { type = "string", enum = { "error", "warning", "hint" } },
        },
        required = { "p", "quote", "suggestions", "issue", "category", "severity" },
        additionalProperties = false,
      },
    },
  },
  required = { "issues" },
  additionalProperties = false,
}

local SYSTEM = [[
You are a meticulous copy editor. You find real errors in a writer's prose and propose minimal fixes.

Report: grammar, agreement, verb tense, articles, prepositions, punctuation, homophones and misspellings a spellchecker misses, wrong word choice, missing or doubled words.%s

Rules:
- Do not report text that is correct, even if you would phrase it differently. Preserve the author's voice. Returning no issues is a good answer.
- quote: the shortest exact span that contains the error, copied verbatim from the paragraph (including any markup characters inside it), normally one to six words. Issues must not overlap; one issue per error.
- suggestions: one to three replacements for exactly the quoted span, best first, keeping any markup inside it.
- issue: what is wrong, in under fifteen words, in the paragraph's language.
- p: the paragraph's number.
- The source is LaTeX, Typst or Markdown. Never touch commands, math, code, citations, labels, references or URLs, and never report them.
- Never translate. Suggestions stay in the paragraph's language.]]

local STYLE = "\nAlso report awkward or wordy phrasing and unclear sentences (category style or clarity, severity hint), sparingly."

local SEV = { error = vim.diagnostic.severity.WARN, warning = vim.diagnostic.severity.INFO, hint = vim.diagnostic.severity.HINT }

local store = issues.store("grammar", {
  source = "claude", severity = SEV, overlap = false, need_fix = true,
  label = function(f) return f.category .. " · " .. f.severity end,
  note = function(f) return f.issue end,
  message = function(f) return f.issue .. (f.suggestions[1] and (" → " .. f.suggestions[1]) or "") end,
})
M.store = store
M.ns_diag = store.ns_diag

local cache
local function get_cache()
  cache = cache or issues.load(issues.json_file("cache", "grammar.json"))
  return cache
end

local function save_cache()
  -- keep the newest 3000 paragraphs
  local keys = vim.tbl_keys(cache)
  if #keys > 3000 then
    table.sort(keys, function(a, b) return (cache[a].t or 0) > (cache[b].t or 0) end)
    for i = 3001, #keys do cache[keys[i]] = nil end
  end
  issues.save(issues.json_file("cache", "grammar.json"), cache)
end

function M.items(buf) return store:items(buf) end
function M.refresh(buf) store:refresh(buf) end
function M.clear(buf) store:clear(buf) end

-- Anchor the cached answers for `paras` (copies: anchoring adds fields).
local function anchor(buf, paras, keys)
  local by = {}
  for _, p in ipairs(paras) do
    local entry = cache[keys[p.id]]
    by[p.id] = vim.deepcopy(entry and entry.issues or {})
  end
  return store:anchor(buf, paras, by)
end

-- ---------------------------------------------------------------------------
-- checking

local function para_key(p, ctx)
  return vim.fn.sha256(table.concat({ ctx.c.model, ctx.c.effort, ctx.style and "style" or "errors",
    ctx.lang, ctx.profile or "", table.concat(ctx.glossary, ","), p.text }, "\31"))
end

local function prompt_for(batch, ctx)
  local parts = {
    "Language: " .. ctx.lang .. ".",
  }
  if ctx.profile then parts[#parts + 1] = "\nThe author's style guide:\n<style_guide>\n" .. ctx.profile .. "\n</style_guide>" end
  if #ctx.glossary > 0 then
    parts[#parts + 1] = "\nCorrect as written, never report: " .. table.concat(ctx.glossary, ", ")
  end
  parts[#parts + 1] = "\nParagraphs:\n"
  for _, p in ipairs(batch) do parts[#parts + 1] = ("[p%d]\n%s\n"):format(p.id, p.text) end
  return table.concat(parts, "\n")
end

--- Check `buf` (all paragraphs, or those touching rows `range` = {s, e}).
--- `o.style` adds style/clarity hints, `o.model` / `o.effort` override the
--- configured ones; cb(n_issues) when done.
function M.check(buf, o, cb)
  buf, o = bufnr(buf), o or {}
  local paras = prose.paragraphs(buf)
  if o.range then
    paras = vim.tbl_filter(function(p) return p.erow >= o.range[1] and p.srow <= o.range[2] end, paras)
  end
  if #paras == 0 then
    vim.notify("No prose to check here", vim.log.levels.WARN, { title = "Grammar" })
    return
  end
  local profile = prose.profile(buf)
  local c = task(o)
  local ctx = { lang = prose.language(buf), profile = profile, glossary = prose.glossary(buf), style = o.style, c = c }
  get_cache()

  local keys, todo = {}, {}
  for _, p in ipairs(paras) do
    keys[p.id] = para_key(p, ctx)
    if not cache[keys[p.id]] then todo[#todo + 1] = p end
  end

  -- batches by size
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
    -- edits while waiting: re-read the paragraphs; changed ones have no answer
    if api.nvim_buf_get_changedtick(buf) ~= tick then
      paras = vim.tbl_filter(function(p) return cache[para_key(p, ctx)] end, prose.paragraphs(buf))
      for _, p in ipairs(paras) do keys[p.id] = para_key(p, ctx) end
    end
    local n = anchor(buf, paras, keys)
    local msg = ("%d issue%s in %d paragraph%s"):format(n, n == 1 and "" or "s", #paras, #paras == 1 and "" or "s")
    if #batches > 0 then msg = msg .. (" (%d new, %d cached)"):format(#todo, #paras - #todo) end
    if #errs > 0 then msg = msg .. "\n" .. table.concat(errs, "\n") end
    vim.notify(msg, #errs > 0 and vim.log.levels.WARN or vim.log.levels.INFO, { title = "Grammar" })
    if cb then cb(n) end
  end

  if #batches == 0 then return finish({}) end
  vim.notify(("Checking %d paragraph%s with %s…"):format(#todo, #todo == 1 and "" or "s", c.model),
    vim.log.levels.INFO, { title = "Grammar" })
  local pending, errs = #batches, {}
  local system = SYSTEM:format(o.style and STYLE or "")
  for _, batch in ipairs(batches) do
    claude.run({
      prompt = prompt_for(batch, ctx), system = system, schema = SCHEMA,
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

-- ---------------------------------------------------------------------------
-- walking

function M.walk(buf, win)
  buf = bufnr(buf)
  W.start({
    key = "grammar:" .. buf, title = "Grammar", win = win,
    issues = function(S) return store:items(S.buf) end, later_key = store.later_key,
    keys = {
      { "d", "dismiss this issue for good", store:dismiss_action() },
      { "t", "talk about it", store:talk_action() },
    },
    footer = " 1-4 fix · e edit · t talk · s skip · l later · d dismiss · u undo · q quit ",
    empty = "No grammar issues", resume_hint = require("writing").hint("<Plug>(WritingGrammar)", ":Writing grammar"),
    on_finish = function(S) store:refresh(S.buf) end,
  })
end

--- Check (cached paragraphs are instant) and walk the issues.
function M.audit(o)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local cur = W.current()
  if cur and cur.key == "grammar:" .. buf and cur.paused then return M.walk(buf, win) end
  M.check(buf, o, function(n)
    if n > 0 and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then M.walk(buf, win) end
  end)
end

return M
