-- Restyle: `rewrite` for every paragraph, with your STYLE.md as the
-- instruction. Claude rewrites each paragraph that goes against the guide
-- (and only those), listing every change with the rule behind it. You walk
-- the paragraphs; the float shows the rewrite as a word diff:
--
--   1 / <CR>   accept the rewrite (one undo step)
--   e          accept it and pause there, to finish it by hand
--   t          talk about it ("keep the first sentence", "it was 37
--              participants"): the reply shows and the rewrite is redone
--   m          insert a TODO(style) comment under the paragraph
--   s skip · l leave for later · d reject for good · u undo · q pause
--
-- What it can't do, it doesn't:
--   * every change must cite a rule found verbatim in the guide, or the
--     paragraph's rewrite is dropped (no invented rules);
--   * a rewrite that loses a citation, reference, label, math, code or URL of
--     the original is dropped (facts.lost);
--   * a rewrite that brings in a number, citation or placeholder the
--     document doesn't have is withheld, and the paragraph is marked "needs
--     input" with what's missing (issues.lua, facts.lua).
-- Per paragraph cache, keyed on the guide, like conform.lua (the
-- finding-by-finding review of the same guide).

local prose = require("writing.prose")
local claude = require("writing.claude")
local issues = require("writing.issues")
local facts = require("writing.facts")
local W = require("writing.walker")

local M = {}

local function task(o) return require("writing.config").task("restyle", o) end

local api = vim.api
local bufnr = issues.bufnr
local norm = issues.norm

local SCHEMA = {
  type = "object",
  properties = {
    paragraphs = {
      type = "array",
      items = {
        type = "object",
        properties = {
          p = { type = "integer", description = "paragraph number" },
          rewrite = { type = "string" },
          changes = {
            type = "array",
            items = {
              type = "object",
              properties = { rule = { type = "string" }, change = { type = "string" } },
              required = { "rule", "change" },
              additionalProperties = false,
            },
          },
          needs = { type = "string" },
        },
        required = { "p", "rewrite", "changes", "needs" },
        additionalProperties = false,
      },
    },
  },
  required = { "paragraphs" },
  additionalProperties = false,
}

local SYSTEM = [[
You are the author's editor. Rewrite each paragraph that goes against the author's style guide so that it follows the guide. The guide is the only standard: change nothing the guide doesn't ask for, and leave out paragraphs that already follow it.

Rules:
- rewrite: the whole paragraph, rewritten. Keep its meaning, voice, language and line structure where it makes sense. Keep every citation, reference, label, math, code, command, URL and markup exactly as written.
- changes: every change you made, each with rule (the guide's rule behind it, copied verbatim from the guide: the shortest exact span that states it) and change (what you changed, under fifteen words).
- Never invent facts. Add no number, date, name, quantity or citation that isn't already in the document, and no placeholders like X, N or [number]. When following a rule needs information only the author has, don't make that change, and say in needs exactly what the author must supply ("the number of participants"). Otherwise needs is "".
- p: the paragraph's number. The source is LaTeX, Typst or Markdown.]]

local function short(s, n)
  s = norm(s)
  return vim.fn.strchars(s) > n and vim.fn.strcharpart(s, 0, n - 1) .. "…" or s
end

local store = issues.store("restyle", {
  source = "restyle", severity = {}, overlap = false, need_fix = true,
  label = function(f)
    return ("%d change%s"):format(#f.changes, #f.changes == 1 and "" or "s")
  end,
  note = function(f)
    local t = {}
    for _, c in ipairs(f.changes) do t[#t + 1] = "• " .. c.change .. " (" .. short(c.rule, 50) .. ")" end
    return table.concat(t, "\n")
  end,
  message = function(f)
    return ("rewrite to follow the style guide: %s"):format(
      table.concat(vim.tbl_map(function(c) return c.change end, f.changes), "; "))
  end,
})
M.store = store
M.ns_diag = store.ns_diag

local cache
local function get_cache()
  cache = cache or issues.load(issues.json_file("cache", "restyle.json"))
  return cache
end

local function save_cache()
  local keys = vim.tbl_keys(cache)
  if #keys > 3000 then
    table.sort(keys, function(a, b) return (cache[a].t or 0) > (cache[b].t or 0) end)
    for i = 3001, #keys do cache[keys[i]] = nil end
  end
  issues.save(issues.json_file("cache", "restyle.json"), cache)
end

--- A model answer for paragraph `p` -> a finding, or nil + why it's dropped
--- ("rule" | "markup"). Unchanged paragraphs give nil.
function M.finding(p, r, guide)
  local g = norm(guide)
  for _, c in ipairs(r.changes or {}) do
    if norm(c.rule) == "" or not g:find(norm(c.rule), 1, true) then return nil, "rule" end
  end
  local rewrite = r.rewrite or ""
  local needs = vim.trim(r.needs or "")
  if norm(rewrite) == norm(p.text) or norm(rewrite) == "" then
    if needs == "" then return nil end
    rewrite = ""
  end
  if rewrite ~= "" and #facts.lost(p.text, rewrite) > 0 then return nil, "markup" end
  return {
    quote = p.text, suggestions = { rewrite }, changes = r.changes or {}, needs = needs,
    issue = "rewrite", category = "restyle", severity = "rewrite",
  }
end

local function anchor(buf, paras, keys, guide)
  local by, dropped = {}, { rule = 0, markup = 0 }
  for _, p in ipairs(paras) do
    local entry = cache[keys[p.id]]
    if entry and entry.answer then
      local f, why = M.finding(p, vim.deepcopy(entry.answer), guide)
      if f then by[p.id] = { f } elseif why then dropped[why] = dropped[why] + 1 end
    end
  end
  return store:anchor(buf, paras, by), dropped
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
    parts[#parts + 1] = "\nCorrect as written, never change: " .. table.concat(ctx.glossary, ", ")
  end
  parts[#parts + 1] = "\nParagraphs:\n"
  for _, p in ipairs(batch) do parts[#parts + 1] = ("[p%d]\n%s\n"):format(p.id, p.text) end
  return table.concat(parts, "\n")
end

--- Rewrite `buf`'s paragraphs to follow its style guide. `o.range` = { s, e }
--- rows, `o.model` / `o.effort`; cb(n) when done.
function M.check(buf, o, cb)
  buf, o = bufnr(buf), o or {}
  local guide, path = prose.profile(buf)
  if not guide or vim.trim(guide) == "" then
    return vim.notify("No STYLE.md found above this file (see :help quill-style-guide)", vim.log.levels.ERROR,
      { title = "Restyle" })
  end
  local paras = prose.paragraphs(buf)
  if o.range then
    paras = vim.tbl_filter(function(p) return p.erow >= o.range[1] and p.srow <= o.range[2] end, paras)
  end
  if #paras == 0 then
    return vim.notify("No prose to restyle here", vim.log.levels.WARN, { title = "Restyle" })
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
    local n, dropped = anchor(buf, paras, keys, guide)
    local msg = ("%d paragraph%s to restyle, against %s"):format(n, n == 1 and "" or "s",
      vim.fn.fnamemodify(path or "the guide", ":~:."))
    local needs = #vim.tbl_filter(function(it) return it.needs ~= nil end, store:items(buf))
    if needs > 0 then msg = msg .. (", %d need%s your input"):format(needs, needs == 1 and "s" or "") end
    if dropped.rule > 0 then msg = msg .. ("\n%d dropped: they cited rules not in the guide"):format(dropped.rule) end
    if dropped.markup > 0 then msg = msg .. ("\n%d dropped: they lost citations or markup"):format(dropped.markup) end
    if #errs > 0 then msg = msg .. "\n" .. table.concat(errs, "\n") end
    vim.notify(msg, #errs > 0 and vim.log.levels.WARN or vim.log.levels.INFO, { title = "Restyle" })
    if cb then cb(n) end
  end

  if #batches == 0 then return finish({}) end
  vim.notify(("Restyling %d paragraph%s with %s…"):format(#todo, #todo == 1 and "" or "s", c.model),
    vim.log.levels.INFO, { title = "Restyle" })
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
        for _, r in ipairs(res.paragraphs or {}) do by[r.p] = r end
        local now = os.time()
        -- unchanged paragraphs are cached too (answer = nil), so they aren't re-sent
        for _, p in ipairs(batch) do cache[keys[p.id]] = { answer = by[p.id], t = now } end
      end
      pending = pending - 1
      if pending == 0 then
        save_cache()
        finish(errs)
      end
    end)
  end
end

-- `e`: accept, then pause on the paragraph so you can finish it by hand.
local function edit(S, it)
  if S.sugg[1] then W.replace(S.sugg[1]) end
  W.pause()
  if api.nvim_win_is_valid(S.win) then api.nvim_win_set_cursor(S.win, { it.row, 0 }) end
end

M.todo = store:todo_action("style", function(it)
  local what = it.needs and ("needs " .. it.needs) or table.concat(
    vim.tbl_map(function(c) return c.change end, it.changes or {}), "; ")
  return "restyle: " .. what
end)

function M.walk(buf, win)
  buf = bufnr(buf)
  W.start({
    key = "restyle:" .. buf, title = "Restyle", win = win, diff = true,
    issues = function(S) return store:items(S.buf) end, later_key = store.later_key,
    keys = {
      { "e", "accept and finish it by hand", edit },
      { "d", "reject for good", store:dismiss_action() },
      { "t", "talk about it", store:talk_action() },
      { "m", "insert a TODO comment", M.todo },
    },
    order = { "fixed", "discussed", "marked", "skipped", "later", "dismissed" },
    footer = " 1 accept · e accept+edit · t talk · m TODO · s skip · l later · d reject · u undo · q quit ",
    empty = "Every paragraph follows the style guide",
    resume_hint = require("writing").hint("<Plug>(WritingRestyle)", ":Writing restyle"),
    on_finish = function(S) store:refresh(S.buf) end,
  })
end

--- Rewrite (cached paragraphs are instant) and walk the paragraphs.
function M.audit(o)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local cur = W.current()
  if cur and cur.key == "restyle:" .. buf and cur.paused then return M.walk(buf, win) end
  M.check(buf, o, function(n)
    if n > 0 and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then M.walk(buf, win) end
  end)
end

return M
