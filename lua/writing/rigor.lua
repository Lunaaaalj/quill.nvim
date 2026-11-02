-- Rigor review: Claude as a peer reviewer of research writing. It reads the
-- whole document (so it can see inconsistencies across sections) and reports
-- loose reasoning, not grammar: unsupported or overclaimed statements,
-- non-sequiturs, named fallacies, inconsistencies, misused statistics, method
-- gaps, undefined terms, unfalsifiable vagueness, and facts worth verifying.
--
-- Results: a report panel on the right (verdict, strengths, priorities, every
-- finding; <CR> jumps, w walks, r re-runs, q closes) and quote-anchored
-- findings walked with the shared walker:
--   1         apply the suggested rewording (hedge, narrow the scope...), when
--             wording alone fixes it
--   e         edit the passage yourself
--   m         mark it: insert a TODO comment (in the file's comment syntax)
--             under the passage, for fixes that need work (a citation, data)
--   t         talk about it: your message, Claude's reply, and a new rewording
--   s skip · l leave for later · d dismiss for good · u undo · q pause
-- Findings are also diagnostics (source "rigor"). The model can't read your
-- sources: a citation counts as support, and doubtful facts are flagged as
-- "verify", never corrected.

local prose = require("writing.prose")
local claude = require("writing.claude")
local issues = require("writing.issues")
local W = require("writing.walker")

local M = {}

local function cfg(o) return require("writing.config").task("rigor", o) end

local api = vim.api
local bufnr = issues.bufnr
local ns_hl = api.nvim_create_namespace("writing_rigor_report")

local TYPES = {
  "unsupported", "overclaim", "non-sequitur", "fallacy", "inconsistency", "statistics", "method",
  "undefined", "ambiguous", "verify",
}

local SCHEMA = {
  type = "object",
  properties = {
    verdict = { type = "string" },
    strengths = { type = "array", items = { type = "string" } },
    priorities = { type = "array", items = { type = "string" } },
    findings = {
      type = "array",
      items = {
        type = "object",
        properties = {
          p = { type = "integer" },
          quote = { type = "string" },
          type = { type = "string", enum = TYPES },
          severity = { type = "string", enum = { "major", "minor" } },
          issue = { type = "string" },
          fix = { type = "string" },
          rewrite = { type = "string" },
          related = { type = "array", items = { type = "integer" } },
        },
        required = { "p", "quote", "type", "severity", "issue", "fix", "rewrite", "related" },
        additionalProperties = false,
      },
    },
  },
  required = { "verdict", "strengths", "priorities", "findings" },
  additionalProperties = false,
}

local SYSTEM = [[
You are a rigorous peer reviewer of research writing (papers, theses, reports). You find weaknesses in reasoning and support. You do not comment on grammar or style.

Look for:
- unsupported: an empirical or factual claim that needs evidence or a citation and has none.
- overclaim: a conclusion stronger than its support: causal language from correlational evidence, "proves", "always", "all", generalising beyond the sample, population or scope.
- non-sequitur: a conclusion that does not follow from what precedes it, or a missing logical step.
- fallacy: a reasoning fallacy (appeal to obviousness, authority or popularity, false dichotomy, circular reasoning, hasty generalisation, post hoc, straw man...). Name it in the issue.
- inconsistency: numbers, definitions, terms or claims that conflict across the document. List the other paragraphs in related.
- statistics: misused or under-reported statistics: no sample size, percentages without a base, significance without effect size, causal claims from observational data.
- method: a methodological gap a reviewer would raise: missing control, confound, selection bias, unclear procedure, unstated limitation.
- undefined: a key term, abbreviation or construct used without definition.
- ambiguous: a claim too vague to check or falsify.
- verify: a specific date, figure or attribution that looks doubtful from general knowledge. You cannot check sources, so phrase it as something to verify, never as a correction.

Rules:
- A citation counts as support; you cannot read the cited work. Flag a cited claim only when it goes beyond what a citation could plausibly support.
- Be selective: report what a careful reviewer would actually raise, most important first. Sound, supported text gets no finding.
- quote: an exact span of the paragraph, copied verbatim with any markup, usually the clause or sentence at fault.
- issue: what is wrong and why, under thirty words. fix: a concrete remedy (add evidence, cite, hedge, define, narrow the scope, report the statistic), under twenty-five words.
- rewrite: if rewording alone fixes it (hedging, narrowing the scope), a replacement for exactly the quote, keeping its markup and citations; otherwise "".
- severity: major if it undermines one of the document's main claims, else minor.
- related: other paragraph numbers involved, else [].
- verdict: two or three sentences on how well the document supports its claims. strengths: up to three. priorities: up to three things to fix first.
- Write everything in the document's language. Ignore markup, math and citations as such.]]

local SEV = { major = vim.diagnostic.severity.WARN, minor = vim.diagnostic.severity.INFO }

local store = issues.store("rigor", {
  source = "rigor", severity = SEV, overlap = true, need_fix = false,
  label = function(f)
    local rel = #(f.related or {}) > 0 and ("  (see ¶" .. table.concat(f.related, ", ¶") .. ")") or ""
    return f.category .. " · " .. f.severity .. rel
  end,
  note = function(f) return f.issue .. "\nFix: " .. f.fix end,
  message = function(f) return f.issue .. " Fix: " .. f.fix end,
})
M.store = store
M.ns_diag = store.ns_diag

local R = {} -- source buf -> { data, paras, buf (report), win }

local function cache_path() return issues.json_file("cache", "rigor.json") end

local function doc_key(c, paras, lang, profile)
  local t = { c.model, c.effort, lang, profile or "" }
  for _, p in ipairs(paras) do t[#t + 1] = p.text end
  return vim.fn.sha256(table.concat(t, "\31"))
end

-- Findings -> store (the type rides in `category`, the rewrite as suggestion).
local function anchor(src, paras, data)
  local by = {}
  for _, f in ipairs(vim.deepcopy(data.findings or {})) do
    by[f.p] = by[f.p] or {}
    table.insert(by[f.p], {
      quote = f.quote, issue = f.issue, fix = f.fix, related = f.related or {},
      category = f.type, severity = f.severity,
      suggestions = (f.rewrite and f.rewrite ~= "") and { f.rewrite } or {},
    })
  end
  return store:anchor(src, paras, by)
end

-- ---------------------------------------------------------------------------
-- walking

-- Insert "TODO(review): …" as a comment under the passage.
local mark = store:todo_action("review", function(it)
  return ("%s: %s Fix: %s"):format(it.category, it.issue, it.fix)
end)

function M.walk(buf, win)
  buf = bufnr(buf)
  W.start({
    key = "rigor:" .. buf, title = "Rigor", win = win,
    issues = function(S) return store:items(S.buf) end, later_key = store.later_key,
    keys = {
      { "m", "mark: insert a TODO comment", mark },
      { "d", "dismiss for good", store:dismiss_action() },
      { "t", "talk about it", store:talk_action() },
    },
    order = { "fixed", "marked", "discussed", "skipped", "later", "dismissed" },
    footer = " 1 apply · e edit · m TODO · t talk · s skip · l later · d dismiss · u undo · q quit ",
    empty = "No rigor findings", resume_hint = require("writing").hint("<Plug>(WritingRigor)", ":Writing rigor"),
    on_finish = function(S) store:refresh(S.buf) end,
  })
end

-- ---------------------------------------------------------------------------
-- report panel

local function render(src)
  local st = R[src]
  local d = st.data
  local lines, hls, map = {}, {}, {}
  local function add(text, groups, target)
    lines[#lines + 1] = text
    map[#lines] = target
    for _, g in ipairs(groups or {}) do hls[#hls + 1] = { #lines - 1, g[1], g[2], g[3] } end
  end
  local function list(title, items, numbered)
    if not items or #items == 0 then return end
    add("")
    add(" " .. title, { { "WritingTitle", 0, -1 } })
    for i, s in ipairs(items) do add((numbered and ("   %d. "):format(i) or "   • ") .. s) end
  end

  add(" Rigor review · " .. vim.fn.fnamemodify(api.nvim_buf_get_name(src), ":t"), { { "WritingTitle", 0, -1 } })
  add(" <CR> jump · w walk findings · r re-run · q close", { { "WritingMuted", 0, -1 } })
  add("")
  add(" Verdict", { { "WritingTitle", 0, -1 } })
  add("   " .. (d.verdict or ""))
  list("Strengths", d.strengths)
  list("Priorities", d.priorities, true)

  local items = store:items(src)
  local major = #vim.tbl_filter(function(it) return it.severity == "major" end, items)
  add("")
  add((" Findings (%d major, %d minor)"):format(major, #items - major), { { "WritingTitle", 0, -1 } })
  for _, sev in ipairs({ "major", "minor" }) do
    for _, it in ipairs(items) do
      if it.severity == sev then
        local head = (" ¶%-3d L%-5d %s %-13s "):format(it.p, it.row, sev == "major" and "●" or "○", it.category)
        local quote = it.text:gsub("%s+", " ")
        if vim.fn.strchars(quote) > 70 then quote = vim.fn.strcharpart(quote, 0, 69) .. "…" end
        local sev_hl = sev == "major" and "WritingMajor" or "WritingMinor"
        add(head .. "“" .. quote .. "”", { { "WritingMuted", 0, 14 }, { sev_hl, 14, #head } }, it.idx)
        add("      " .. it.issue, {}, it.idx)
        add("      Fix: " .. it.fix, { { "WritingRole", 6, 10 } }, it.idx)
      end
    end
  end
  st.map = map

  vim.bo[st.buf].modifiable = true
  api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  api.nvim_buf_clear_namespace(st.buf, ns_hl, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(st.buf, ns_hl, h[1], h[3], {
      end_row = h[4] == -1 and h[1] + 1 or h[1], end_col = h[4] ~= -1 and h[4] or 0, hl_group = h[2],
    })
  end
end

local function source_win(src)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == src and api.nvim_win_get_config(w).relative == "" then return w end
  end
end

local function jump(src)
  local st = R[src]
  local idx = st.map[api.nvim_win_get_cursor(0)[1]]
  local win = source_win(src)
  if not (idx and win) then return end
  for _, it in ipairs(store:items(src)) do
    if it.idx == idx then
      api.nvim_set_current_win(win)
      api.nvim_win_set_cursor(win, { it.row, it.col })
      vim.cmd("normal! zvzz")
      return
    end
  end
end

local function open_panel(src)
  local st = R[src]
  if not (st.buf and api.nvim_buf_is_valid(st.buf)) then
    st.buf = api.nvim_create_buf(false, true)
    vim.bo[st.buf].bufhidden = "hide"
    vim.bo[st.buf].filetype = "writingoutline" -- same panel look and filetype as the outline
    pcall(api.nvim_buf_set_name, st.buf, "writing://rigor/" .. src)
    local function map(lhs, fn, desc) vim.keymap.set("n", lhs, fn, { buffer = st.buf, nowait = true, desc = desc }) end
    map("<CR>", function() jump(src) end, "Rigor: jump to finding")
    map("w", function()
      local win = source_win(src)
      if win then M.walk(src, win) end
    end, "Rigor: walk findings")
    map("r", function() M.review({ force = true, src = src }) end, "Rigor: re-run")
    map("q", function() if api.nvim_win_is_valid(st.win) then api.nvim_win_close(st.win, true) end end, "Rigor: close")
  end
  if not (st.win and api.nvim_win_is_valid(st.win)) then
    local cur = api.nvim_get_current_win()
    vim.cmd("botright vertical " .. cfg().width .. "split")
    st.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(st.win, st.buf)
    for k, v in pairs({ wrap = true, linebreak = true, breakindent = true, number = false, relativenumber = false,
      signcolumn = "no", foldcolumn = "0", spell = false, winfixwidth = true, cursorline = true }) do
      vim.wo[st.win][k] = v
    end
    vim.wo[st.win].breakindentopt = "shift:6"
    api.nvim_set_current_win(cur)
  end
end

-- ---------------------------------------------------------------------------
-- running

--- Review the current buffer (cached per document unless `o.force`), show the
--- report and walk the findings.
function M.review(o)
  o = o or {}
  local src = bufnr(o.src)
  local win = source_win(src) or api.nvim_get_current_win()
  local cur = W.current()
  if not o.force and cur and cur.key == "rigor:" .. src and cur.paused then return M.walk(src, win) end
  local paras = prose.paragraphs(src)
  if #paras == 0 then
    return vim.notify("No prose to review", vim.log.levels.WARN, { title = "Rigor" })
  end
  local lang, profile = prose.language(src), prose.profile(src)
  local c = cfg(o)
  local key = doc_key(c, paras, lang, profile)
  local cache = issues.load(cache_path())

  local function show(data)
    if not api.nvim_buf_is_valid(src) then return end
    R[src] = R[src] or {}
    R[src].data, R[src].paras = data, paras
    local n = anchor(src, paras, data)
    open_panel(src)
    render(src)
    vim.notify(("%d finding%s"):format(n, n == 1 and "" or "s"), vim.log.levels.INFO, { title = "Rigor" })
    if n > 0 and api.nvim_win_is_valid(win) then M.walk(src, win) end
  end

  if cache[key] and not o.force then return show(cache[key]) end

  local tick = api.nvim_buf_get_changedtick(src)
  local parts = { "Language: " .. lang .. "." }
  if profile then parts[#parts + 1] = "\nThe author's style guide:\n<style_guide>\n" .. profile .. "\n</style_guide>" end
  parts[#parts + 1] = "\nDocument:\n"
  for _, p in ipairs(paras) do parts[#parts + 1] = ("[p%d]\n%s\n"):format(p.id, p.text) end

  vim.notify(("Reviewing %d paragraphs with %s…"):format(#paras, c.model), vim.log.levels.INFO,
    { title = "Rigor" })
  claude.run({
    prompt = table.concat(parts, "\n"), system = SYSTEM, schema = SCHEMA,
    model = c.model, effort = c.effort,
  }, function(err, data)
    if err then return vim.notify(err, vim.log.levels.ERROR, { title = "Rigor" }) end
    cache = issues.load(cache_path())
    cache[key] = data
    local keys = vim.tbl_keys(cache)
    if #keys > 50 then for i = 51, #keys do cache[keys[i]] = nil end end
    issues.save(cache_path(), cache)
    -- edited while waiting: findings whose quotes are gone simply won't anchor
    if api.nvim_buf_get_changedtick(src) ~= tick then paras = prose.paragraphs(src) end
    show(data)
  end)
end

function M.setup()
  api.nvim_create_augroup("writing_rigor", { clear = true })
  -- keep the report's finding list in step as you fix things
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = "writing_rigor",
    callback = function(ev)
      local st = R[ev.buf]
      if st and st.buf and api.nvim_buf_is_valid(st.buf) then
        vim.schedule(function() if R[ev.buf] then render(ev.buf) end end)
      end
    end,
  })
end

return M
