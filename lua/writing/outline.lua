-- Reverse outline: Claude summarises every paragraph in a line, names its role
-- in the argument, and flags real problems (unsupported claims, gaps,
-- contradictions, undefined terms...), plus document-level notes. It shows in
-- a panel to the right; the flags are also diagnostics in the source.
--
-- Panel keys: <CR> jump to the paragraph, ]f / [f next / previous flag,
-- r re-run (ignores the cache), q close. The entry for the paragraph under
-- the source cursor is highlighted as you move.

local prose = require("writing.prose")
local claude = require("writing.claude")

local M = {}

local function cfg(o) return require("writing.config").task("outline", o) end

local api = vim.api
local ns = api.nvim_create_namespace("writing_outline")
local ns_anchor = api.nvim_create_namespace("writing_outline_anchor")
local ns_diag = api.nvim_create_namespace("writing_outline_diag")
local ns_cur = api.nvim_create_namespace("writing_outline_current")
M.ns_diag = ns_diag

local ROLES = {
  "heading", "thesis", "claim", "evidence", "example", "method", "result", "definition", "background",
  "counterargument", "rebuttal", "transition", "conclusion", "other",
}
local FLAGS = {
  "unsupported", "gap", "contradiction", "undefined-term", "off-topic", "redundant", "unclear", "weak-transition",
}

local SCHEMA = {
  type = "object",
  properties = {
    thesis = { type = "string" },
    paragraphs = {
      type = "array",
      items = {
        type = "object",
        properties = {
          p = { type = "integer" },
          summary = { type = "string" },
          role = { type = "string", enum = ROLES },
          flags = {
            type = "array",
            items = {
              type = "object",
              properties = {
                type = { type = "string", enum = FLAGS },
                note = { type = "string" },
              },
              required = { "type", "note" },
              additionalProperties = false,
            },
          },
        },
        required = { "p", "summary", "role", "flags" },
        additionalProperties = false,
      },
    },
    overall = {
      type = "array",
      items = {
        type = "object",
        properties = {
          type = { type = "string", enum = { "structure", "gap", "contradiction", "missing", "order", "focus" } },
          note = { type = "string" },
          paragraphs = { type = "array", items = { type = "integer" } },
        },
        required = { "type", "note", "paragraphs" },
        additionalProperties = false,
      },
    },
  },
  required = { "thesis", "paragraphs", "overall" },
  additionalProperties = false,
}

local SYSTEM = [[
You are a developmental editor. You build a reverse outline of a document so its author can see the argument's structure and where it breaks.

For every paragraph [pN]:
- summary: what the paragraph says or does, in one plain sentence under twenty words.
- role: its job in the argument.
- flags: only real problems a careful reviewer would raise (usually none): a claim with no support where support is expected (unsupported), a missing logical step from what came before (gap), a conflict with another paragraph (contradiction, name it), a term used before it is defined (undefined-term), content that doesn't serve the document's point (off-topic), a repeat of an earlier paragraph (redundant), a paragraph whose point you can't state (unclear), or an abrupt jump (weak-transition). Each note says specifically what is wrong, in under twenty-five words.

thesis: the document's main point in one sentence, as the text actually argues it (not as it should).
overall: up to five document-level observations (structure, order, missing pieces, focus), each naming the paragraph numbers involved. Leave it empty if nothing stands out.

Write everything in the document's language. Ignore markup, math and citations as such; judge the prose.]]

local P = {} -- source buf -> { buf, win, data, anchors, lines }

local function cache_path()
  local dir = vim.fn.stdpath("cache") .. "/writing"
  vim.fn.mkdir(dir, "p")
  return dir .. "/outline.json"
end

local function load_cache()
  local f = cache_path()
  if vim.fn.filereadable(f) == 0 then return {} end
  local ok, v = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), "\n"))
  return ok and type(v) == "table" and v or {}
end

local function doc_key(c, paras, lang, profile)
  local t = { c.model, c.effort, lang, profile or "" }
  for _, p in ipairs(paras) do t[#t + 1] = p.text end
  return vim.fn.sha256(table.concat(t, "\31"))
end

-- ---------------------------------------------------------------------------
-- panel

local function source_win(src)
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(w) == src and api.nvim_win_get_config(w).relative == "" then return w end
  end
end

local function anchor_row(src, st, p)
  local m = st.anchors[p] and api.nvim_buf_get_extmark_by_id(src, ns_anchor, st.anchors[p], {})
  return m and m[1] and m[1] + 1
end

local function jump(src)
  local st = P[src]
  local entry = st.lines[api.nvim_win_get_cursor(0)[1]]
  if not entry then return end
  local p = type(entry) == "table" and entry[1] or entry
  local row = anchor_row(src, st, p)
  local win = source_win(src)
  if not (row and win) then return end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { row, 0 })
  vim.cmd("normal! zvzz")
end

local function next_flag(dir)
  local cur = api.nvim_win_get_cursor(0)[1]
  local n = api.nvim_buf_line_count(0)
  local i = cur + dir
  while i >= 1 and i <= n do
    local l = api.nvim_buf_get_lines(0, i - 1, i, false)[1]
    if l:find("⚠", 1, true) then return api.nvim_win_set_cursor(0, { i, 0 }) end
    i = i + dir
  end
end

local function render(src)
  local st = P[src]
  local d = st.data
  local lines, hls, map = {}, {}, {}
  local function add(text, groups, entry)
    lines[#lines + 1] = text
    map[#lines] = entry
    for _, g in ipairs(groups or {}) do hls[#hls + 1] = { #lines - 1, g[1], g[2], g[3] } end
  end
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(src), ":t")
  add(" Reverse outline · " .. name, { { "WritingTitle", 0, -1 } })
  add(" <CR> jump · ]f/[f flags · r re-run · q close", { { "WritingMuted", 0, -1 } })
  add("")
  add(" Thesis", { { "WritingTitle", 0, -1 } })
  add("   " .. (d.thesis or ""), {})
  add("")
  local by = {}
  for _, e in ipairs(d.paragraphs or {}) do by[e.p] = e end
  local nflags = 0
  for _, p in ipairs(st.paras) do
    local e = by[p.id]
    if e then
      local row = anchor_row(src, st, p.id) or p.srow
      if e.role == "heading" then
        if lines[#lines] ~= "" then add("") end
        add((" § %s"):format(vim.trim(p.text:gsub("^[#=%s]+", ""):gsub("\\%a+%*?{(.-)}", "%1"))),
          { { "WritingHeading", 0, -1 } }, p.id)
      else
        local head = (" ¶%-3d L%-5d %-15s "):format(p.id, row, e.role)
        add(head .. e.summary, { { "WritingMuted", 0, #head - 16 }, { "WritingRole", #head - 16, #head } }, p.id)
      end
      for _, f in ipairs(e.flags or {}) do
        nflags = nflags + 1
        local t = ("      ⚠ %s: %s"):format(f.type, f.note)
        add(t, { { "WritingFlag", 0, 11 + #f.type } }, p.id)
      end
    end
  end
  if d.overall and #d.overall > 0 then
    add("")
    add(" Overall", { { "WritingTitle", 0, -1 } })
    for _, o in ipairs(d.overall) do
      local refs = #o.paragraphs > 0 and (" (¶" .. table.concat(o.paragraphs, ", ¶") .. ")") or ""
      add(("   ⚠ %s: %s%s"):format(o.type, o.note, refs), { { "WritingFlag", 0, 8 + #o.type } }, o.paragraphs[1])
    end
  end
  st.lines = map

  local buf = st.buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(buf, ns, h[1], h[3], {
      end_row = h[4] == -1 and h[1] + 1 or h[1], end_col = h[4] ~= -1 and h[4] or 0, hl_group = h[2],
    })
  end

  -- flags as diagnostics on the paragraphs
  local diags = {}
  for _, p in ipairs(st.paras) do
    for _, f in ipairs(by[p.id] and by[p.id].flags or {}) do
      local row = anchor_row(src, st, p.id) or p.srow
      diags[#diags + 1] = {
        lnum = row - 1, col = 0, severity = vim.diagnostic.severity.INFO,
        message = f.type .. ": " .. f.note, source = "outline", code = f.type,
      }
    end
  end
  vim.diagnostic.set(ns_diag, src, diags)
  return nflags
end

-- Highlight the entry of the paragraph under the source cursor.
local function follow(src)
  local st = P[src]
  if not (st and st.win and api.nvim_win_is_valid(st.win) and st.paras) then return end
  local row = api.nvim_win_get_cursor(0)[1]
  local cur
  for _, p in ipairs(st.paras) do
    local r = anchor_row(src, st, p.id) or p.srow
    if r <= row then cur = p.id end
  end
  api.nvim_buf_clear_namespace(st.buf, ns_cur, 0, -1)
  for i, e in pairs(st.lines) do
    if e == cur and api.nvim_buf_get_lines(st.buf, i - 1, i, false)[1]:find("¶", 1, true) then
      api.nvim_buf_set_extmark(st.buf, ns_cur, i - 1, 0, { line_hl_group = "WritingCurrent" })
      if api.nvim_get_current_win() ~= st.win then
        api.nvim_win_call(st.win, function()
          local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
          if i < top or i > bot then api.nvim_win_set_cursor(st.win, { i, 0 }); vim.cmd("normal! zz") end
        end)
      end
      break
    end
  end
end

local function open_panel(src)
  local st = P[src]
  if not (st.buf and api.nvim_buf_is_valid(st.buf)) then
    st.buf = api.nvim_create_buf(false, true)
    vim.bo[st.buf].bufhidden = "hide"
    vim.bo[st.buf].filetype = "writingoutline"
    local name = "writing://outline/" .. src
    pcall(api.nvim_buf_set_name, st.buf, name)
    local function map(lhs, fn, desc) vim.keymap.set("n", lhs, fn, { buffer = st.buf, nowait = true, desc = desc }) end
    map("<CR>", function() jump(src) end, "Outline: jump to paragraph")
    map("]f", function() next_flag(1) end, "Outline: next flag")
    map("[f", function() next_flag(-1) end, "Outline: previous flag")
    map("r", function() M.open({ force = true, src = src }) end, "Outline: re-run")
    map("q", function() if api.nvim_win_is_valid(st.win) then api.nvim_win_close(st.win, true) end end, "Outline: close")
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
    vim.wo[st.win].breakindentopt = "shift:8"
    api.nvim_set_current_win(cur)
  end
end

--- Build (or show the cached) reverse outline of the current buffer.
function M.open(o)
  o = o or {}
  local src = o.src or api.nvim_get_current_buf()
  local paras = prose.paragraphs(src)
  if #paras < 2 then
    return vim.notify("Not enough prose for an outline", vim.log.levels.WARN, { title = "Outline" })
  end
  local lang, profile = prose.language(src), prose.profile(src)
  local c = cfg(o)
  local key = doc_key(c, paras, lang, profile)
  local cache = load_cache()

  P[src] = P[src] or {}
  local st = P[src]
  local function show(data)
    if not api.nvim_buf_is_valid(src) then return end
    api.nvim_buf_clear_namespace(src, ns_anchor, 0, -1)
    st.anchors, st.paras, st.data = {}, paras, data
    for _, p in ipairs(paras) do
      st.anchors[p.id] = api.nvim_buf_set_extmark(src, ns_anchor, p.srow - 1, 0, {})
    end
    open_panel(src)
    local n = render(src)
    vim.notify(("%d paragraphs, %d flag%s"):format(#paras, n, n == 1 and "" or "s"), vim.log.levels.INFO,
      { title = "Outline" })
  end

  if cache[key] and not o.force then return show(cache[key]) end

  local parts = { "Language: " .. lang .. "." }
  if profile then parts[#parts + 1] = "\nThe author's style guide:\n<style_guide>\n" .. profile .. "\n</style_guide>" end
  parts[#parts + 1] = "\nDocument:\n"
  for _, p in ipairs(paras) do parts[#parts + 1] = ("[p%d]\n%s\n"):format(p.id, p.text) end

  vim.notify(("Outlining %d paragraphs with %s…"):format(#paras, c.model), vim.log.levels.INFO,
    { title = "Outline" })
  claude.run({
    prompt = table.concat(parts, "\n"), system = SYSTEM, schema = SCHEMA,
    model = c.model, effort = c.effort,
  }, function(err, data)
    if err then return vim.notify(err, vim.log.levels.ERROR, { title = "Outline" }) end
    cache = load_cache()
    cache[key] = data
    -- keep the newest 50 outlines
    local keys = vim.tbl_keys(cache)
    if #keys > 50 then for i = 51, #keys do cache[keys[i]] = nil end end
    vim.fn.writefile({ vim.json.encode(cache) }, cache_path())
    show(data)
  end)
end

function M.setup()
  local group = api.nvim_create_augroup("writing_outline", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(ev) if P[ev.buf] then follow(ev.buf) end end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev) P[ev.buf] = nil end,
  })
end

return M
