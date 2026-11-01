-- The audit walker: one issue at a time in a float under it, jumping to the
-- next after each action. Sources supply the issues; this owns the float, the
-- highlight, skips, undo and the summary. Used by the spell audit
-- (spell.lua), the grammar audit (grammar.lua) and the rigor review (rigor.lua).
--
-- A source:
--   title        "Spell", shown in the float's title
--   key          identity for resuming a paused audit
--   buf, win     the buffer under audit and the window showing it
--   issues(S)    current issues, rescanned after every action, as
--                { row, col, end_row, end_col (1-based rows, 0-based byte
--                  cols, end exclusive), text, label, note?, suggestions? }
--   suggestions(S, issue)?   lazily computed suggestions (else issue.suggestions)
--   keys         extra actions { lhs, desc, fn(S, issue, W) }
--   footer       the key hint
--   empty        message when there's nothing to do
--   on_finish(S, stopped)?
--
-- Common keys: 1-9 / <CR> replace with a suggestion, e type a replacement,
-- s / <Space> skip, u undo the last action, q / <Esc> pause.

local W = {}

local api = vim.api
local ns = api.nvim_create_namespace("audit_walker") -- highlight of the current issue
W.ns_skip = api.nvim_create_namespace("audit_walker_skip")

local S -- the running (or paused) audit

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = S and (S.title .. " audit") or "Audit" })
end

local function skipped(buf, row, col)
  return #api.nvim_buf_get_extmarks(buf, W.ns_skip, { row - 1, col }, { row - 1, col }, {}) > 0
end

local function close_float()
  if S and S.float and api.nvim_win_is_valid(S.float) then
    S.closing = true
    api.nvim_win_close(S.float, true)
    S.closing = false
  end
end

local function summary(s)
  local parts = {}
  for _, k in ipairs(s.order) do
    if (s.count[k] or 0) > 0 then parts[#parts + 1] = ("%d %s"):format(s.count[k], k) end
  end
  return #parts > 0 and table.concat(parts, ", ") or "nothing changed"
end

local function finish(stopped)
  if not S then return end
  local s = S
  close_float()
  if api.nvim_buf_is_valid(s.buf) then api.nvim_buf_clear_namespace(s.buf, ns, 0, -1) end
  if api.nvim_win_is_valid(s.win) then api.nvim_set_current_win(s.win) end
  if stopped then
    s.paused = true -- keep the counts and skips for a resume
    notify(("Paused (%s). %s again resumes."):format(summary(s), s.resume_hint or "Start it"))
  else
    S = nil
    if api.nvim_buf_is_valid(s.buf) then api.nvim_buf_clear_namespace(s.buf, W.ns_skip, 0, -1) end
    notify(s.total == 0 and s.empty or "Done: " .. summary(s))
  end
  if s.on_finish then s.on_finish(s, stopped) end
end

local function done()
  local n = 0
  for _, v in pairs(S.count) do n = n + v end
  return n
end

-- Display-width-aware wrap of `text` into lines of at most `width` cells.
local function wrap(text, width)
  local out, line = {}, ""
  for word in (text or ""):gmatch("%S+") do
    if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
      out[#out + 1] = line
      line = word
    else
      line = line == "" and word or line .. " " .. word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

-- Lines of the float and where things are on them.
local function build(issue, sugg, width)
  local lines, hls = {}, {}
  local function add(text, groups)
    lines[#lines + 1] = text
    for _, g in ipairs(groups or {}) do hls[#hls + 1] = { #lines - 1, g[1], g[2], g[3] } end
  end

  -- The issue's first line, trimmed around it.
  local text = api.nvim_buf_get_lines(S.buf, issue.row - 1, issue.row, false)[1] or ""
  local s = issue.col
  local e = issue.end_row == issue.row and issue.end_col or #text
  local bad = text:sub(s + 1, e)
  local room = width - 4
  local left = math.max(0, s - math.floor((room - vim.fn.strdisplaywidth(bad)) / 2))
  local pre = (left > 0 and "…" or "") .. text:sub(left + 1, s):gsub("^%s+", "")
  local post = text:sub(e + 1, e + math.max(0, room - vim.fn.strdisplaywidth(pre) - vim.fn.strdisplaywidth(bad)))
  if e + #post < #text then post = post .. "…" end
  if issue.end_row > issue.row then post = "…" end
  add(" " .. pre .. bad .. post, { { "SpellAuditMuted", 0, -1 }, { "SpellAuditBad", 1 + #pre, 1 + #pre + #bad } })
  add(" " .. (issue.label or ""), { { "SpellAuditMuted", 0, -1 } })
  for _, para in ipairs(vim.split(issue.note or "", "\n", { trimempty = true })) do
    for _, l in ipairs(wrap(para, width - 2)) do add(" " .. l) end
  end
  add("")

  local first = #lines + 1
  if #sugg == 0 then add("   no suggestions", { { "SpellAuditMuted", 0, -1 } }) end
  for i, w in ipairs(sugg) do
    local shown = w:gsub("\n", "⏎")
    add(("  %d  %s"):format(i, shown), { { "SpellAuditAccent", 2, 3 } })
  end
  return lines, hls, first
end

local function render(issue)
  local buf, win = S.buf, S.win
  S.issue = issue
  S.pos = { issue.row, issue.col }

  -- Put the issue on screen and mark it.
  api.nvim_win_set_cursor(win, { issue.row, issue.col })
  api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zv")
    local wl, wh = vim.fn.winline(), api.nvim_win_get_height(0)
    if wl < 3 or wl > wh - 3 then vim.cmd("normal! zz") end
  end)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_set_extmark(buf, ns, issue.row - 1, issue.col, {
    end_row = issue.end_row - 1, end_col = issue.end_col, hl_group = "SpellAuditWord", priority = 300,
  })

  S.sugg = S.suggestions and S.suggestions(S, issue) or issue.suggestions or {}

  local width = math.max(vim.fn.strdisplaywidth(S.footer) + 2, 44)
  for _, w in ipairs(S.sugg) do width = math.max(width, vim.fn.strdisplaywidth(w) + 8) end
  width = math.min(width, 100, api.nvim_win_get_width(win) - 2)
  local lines, hls, first = build(issue, S.sugg, width)
  S.first = first

  if not (S.fbuf and api.nvim_buf_is_valid(S.fbuf)) then
    S.fbuf = api.nvim_create_buf(false, true)
    vim.bo[S.fbuf].bufhidden = "wipe"
    vim.bo[S.fbuf].filetype = "spellaudit" -- its cursorline is the selection
    W.keymaps(S.fbuf)
  end
  vim.bo[S.fbuf].modifiable = true
  api.nvim_buf_set_lines(S.fbuf, 0, -1, false, lines)
  vim.bo[S.fbuf].modifiable = false
  api.nvim_buf_clear_namespace(S.fbuf, ns, 0, -1)
  for _, h in ipairs(hls) do
    api.nvim_buf_set_extmark(S.fbuf, ns, h[1], h[3], {
      end_row = h[4] == -1 and h[1] + 1 or h[1], end_col = h[4] ~= -1 and h[4] or 0, hl_group = h[2],
    })
  end

  -- Below the issue, or above it when there's no room.
  local height = #lines
  local below = api.nvim_win_call(win, vim.fn.winline) + height + 3 <= api.nvim_win_get_height(win)
  local cfg = {
    relative = "win", win = win, bufpos = { issue.row - 1, issue.col },
    row = below and 1 or 0, col = -2, anchor = below and "NW" or "SW",
    width = width, height = height, border = "rounded", style = "minimal",
    title = (" %s %d/%d "):format(S.title, done() + 1, done() + S.remaining), title_pos = "left",
    footer = S.footer, footer_pos = "center",
  }
  if S.float and api.nvim_win_is_valid(S.float) then
    api.nvim_win_set_config(S.float, cfg)
  else
    cfg.zindex = 60
    S.float = api.nvim_open_win(S.fbuf, true, cfg)
    vim.wo[S.float].cursorline = true
    vim.wo[S.float].winhighlight = "CursorLine:SpellAuditSel,FloatTitle:SpellAuditTitle,FloatFooter:SpellAuditMuted"
    vim.wo[S.float].winblend = 0
    api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(S.float), once = true,
      callback = function() if S and not S.closing then vim.schedule(function() finish(true) end) end end,
    })
  end
  api.nvim_set_current_win(S.float)
  api.nvim_win_set_cursor(S.float, { first, 0 })
end

-- Show the first issue at or after the last position (wrapping around).
function W.step()
  if not S then return end
  if not (api.nvim_win_is_valid(S.win) and api.nvim_buf_is_valid(S.buf)) then return finish(true) end
  local list = vim.tbl_filter(function(it) return not skipped(S.buf, it.row, it.col) end, S.issues(S))
  table.sort(list, function(a, b) return a.row < b.row or (a.row == b.row and a.col < b.col) end)
  S.remaining = #list
  if #list == 0 then return finish(false) end
  local pick = list[1]
  for _, it in ipairs(list) do
    if it.row > S.pos[1] or (it.row == S.pos[1] and it.col >= S.pos[2]) then pick = it break end
  end
  render(pick)
end

--- Record an action for the summary and `u`. `entry.change` (from
--- checkpoint()) undoes a buffer edit, `entry.undo(S)` anything else (both
--- may be given); `entry.n` counts it n times.
function W.push(entry)
  entry.pos = { S.issue.row, S.issue.col }
  S.history[#S.history + 1] = entry
  S.count[entry.kind] = (S.count[entry.kind] or 0) + (entry.n or 1)
end

-- Start a new undo block and return the change number to undo back to, so
-- `u` reverts exactly one action even when edits arrive in one input burst.
function W.checkpoint()
  return api.nvim_buf_call(S.buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels") -- breaks the undo sequence
    return vim.fn.changenr()
  end)
end

--- Replace the current issue's range with `text`.
function W.replace(text)
  local it = S.issue
  local before = W.checkpoint()
  api.nvim_buf_set_text(S.buf, it.row - 1, it.col, it.end_row - 1, it.end_col, vim.split(text, "\n"))
  W.push({ kind = "fixed", change = before })
end

local function selected()
  local i = api.nvim_win_get_cursor(S.float)[1] - S.first + 1
  return S.sugg[i]
end
W.selected = selected

local actions = {}

function actions.pick(i)
  local w = S.sugg[i]
  if w then W.replace(w); W.step() end
end

function actions.cr()
  local w = selected()
  if w then W.replace(w); W.step() end
end

function actions.edit()
  local it = S.issue
  vim.ui.input({ prompt = "Replace “" .. it.text .. "” with: ", default = selected() or it.text }, function(text)
    if not S then return end
    if text and text ~= "" and text ~= it.text then W.replace(text) end
    W.step()
  end)
end

function actions.skip()
  local it = S.issue
  local id = api.nvim_buf_set_extmark(S.buf, W.ns_skip, it.row - 1, it.col, {})
  W.push({ kind = "skipped", undo = function(s) pcall(api.nvim_buf_del_extmark, s.buf, W.ns_skip, id) end })
  S.pos = { it.row, it.col + 1 }
  W.step()
end

function actions.undo()
  local e = table.remove(S.history)
  if not e then return notify("Nothing to undo", vim.log.levels.WARN) end
  S.count[e.kind] = S.count[e.kind] - (e.n or 1)
  if e.change then api.nvim_buf_call(S.buf, function() vim.cmd("silent undo " .. e.change) end) end
  if e.undo then e.undo(S) end
  S.pos = e.pos
  W.step()
end

function actions.quit() finish(true) end

function W.keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Audit: " .. desc })
  end
  for i = 1, 9 do map(tostring(i), function() actions.pick(i) end, "use suggestion " .. i) end
  map("<CR>", actions.cr, "use suggestion under cursor")
  map("e", actions.edit, "type a replacement")
  map("s", actions.skip, "skip")
  map("<Space>", actions.skip, "skip")
  map("u", actions.undo, "undo last action")
  map("q", actions.quit, "stop")
  map("<Esc>", actions.quit, "stop")
  for _, k in ipairs(S.keys or {}) do
    map(k[1], function() k[3](S, S.issue, W) end, k[2])
  end
end

--- Start (or resume) an audit for `source` (see the header).
function W.start(source)
  if S and S.float and api.nvim_win_is_valid(S.float) then
    if S.key == source.key then return api.nvim_set_current_win(S.float) end
    finish(true)
  end
  local win = source.win or api.nvim_get_current_win()
  if S and S.paused and S.key == source.key and api.nvim_buf_is_valid(S.buf) and S.buf == api.nvim_win_get_buf(win) then
    S.paused, S.win = false, win
    return W.step()
  end
  S = vim.tbl_extend("force", {
    win = win, buf = api.nvim_win_get_buf(win),
    pos = { 1, 0 }, history = {}, count = {},
    order = { "fixed", "skipped", "ignored", "added", "dismissed" },
    empty = "Nothing to fix", footer = " 1-9 fix · e edit · s skip · u undo · q quit ",
  }, source)
  if S.on_start then S.on_start(S) end
  S.total = #S.issues(S)
  W.step()
end

function W.current() return S end

return W
