-- Quote-anchored issues, shared by the grammar audit, the STYLE.md check and
-- the rigor review.
--
-- Claude answers with verbatim quotes per paragraph; `store:anchor()` finds
-- each in its paragraph (prose.locate), drops what isn't there (that's how
-- hallucinated findings die), and keeps the rest as extmarks, so they move
-- with your edits. `store:items()` returns only those whose current text still
-- equals the quote: fixed ones vanish and `u` (extmark undo_restore) brings
-- them back. Every store mirrors its items as diagnostics in its own
-- namespace, and remembers dismissals in stdpath("state")/writing.
--
-- A finding's `key` is fixed when it's anchored (store, quote, first
-- suggestion, issue): dismissals and "later" use it, so they survive a talk
-- (`t`) that replaces the suggestions. This file also keeps the "later" set
-- the walker uses, and the talk action.

local prose = require("writing.prose")

local I = {}

local api = vim.api

function I.bufnr(buf) return (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf end

function I.json_file(base, name)
  local dir = vim.fn.stdpath(base) .. "/writing"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. name
end

function I.load(path)
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, v = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(v) == "table" and v or {}
end

function I.save(path, tbl) vim.fn.writefile({ vim.json.encode(tbl) }, path) end

function I.norm(s) return vim.trim((s or ""):gsub("%s+", " ")) end
local norm = I.norm

local dismissed
local function get_dismissed()
  dismissed = dismissed or I.load(I.json_file("state", "dismissed.json"))
  return dismissed
end

-- Items left for later (walker `l`): key -> true, in stdpath("state").
local later
function I.later()
  later = later or I.load(I.json_file("state", "later.json"))
  return later
end

function I.set_later(key, on)
  I.later()[key] = on or nil
  I.save(I.json_file("state", "later.json"), later)
end

local Store = {}
Store.__index = Store

--- A store. `o`:
---   source        diagnostic source name ("claude", "rigor")
---   severity      map from finding severity to vim.diagnostic.severity
---   overlap       keep findings that overlap an earlier one (rigor) or drop them (grammar)
---   need_fix      drop findings with no useful suggestion (grammar)
---   label(f), note(f), message(f)   how a finding reads in the walker / diagnostics
local stores = {}

function I.store(name, o)
  local s = setmetatable({
    name = name, o = o, B = {},
    ns = api.nvim_create_namespace("writing_" .. name),
    ns_diag = api.nvim_create_namespace("writing_" .. name .. "_diag"),
  }, Store)
  stores[#stores + 1] = s
  return s
end

--- Keep every store's diagnostics in step with edits (fixed issues vanish).
function I.setup()
  local group = api.nvim_create_augroup("writing_issues", { clear = true })
  local timer = vim.uv.new_timer()
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(ev)
      timer:stop()
      timer:start(300, 0, vim.schedule_wrap(function()
        for _, s in ipairs(stores) do
          if s.B[ev.buf] then s:refresh(ev.buf) end
        end
      end))
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      for _, s in ipairs(stores) do s.B[ev.buf] = nil end
    end,
  })
end

function Store:dismiss_key(f)
  return vim.fn.sha256(self.name .. "\31" .. f.quote .. "\31" .. (f.suggestions[1] or "") .. "\31" .. (f.issue or ""))
end

--- Live items of `buf`, with walker fields (row/col/end_row/end_col/text/label/note).
function Store:items(buf)
  buf = I.bufnr(buf)
  local st = self.B[buf]
  if not st then return {} end
  local out = {}
  for idx, f in ipairs(st.items) do
    local m = api.nvim_buf_get_extmark_by_id(buf, self.ns, f.mark, { details = true })
    if m[1] and not f.dismissed and not f.handled then
      local r1, c1, r2, c2 = m[1], m[2], m[3].end_row, m[3].end_col
      local ok, text = pcall(api.nvim_buf_get_text, buf, r1, c1, r2, c2, {})
      text = ok and table.concat(text, "\n") or ""
      if norm(text) == norm(f.quote) and norm(text) ~= "" then
        local note = self.o.note(f)
        local last = f.talk and f.talk[#f.talk]
        if last then note = note .. "\n› " .. last.reply end
        out[#out + 1] = vim.tbl_extend("force", f, {
          idx = idx, row = r1 + 1, col = c1, end_row = r2 + 1, end_col = c2, text = text,
          label = self.o.label(f), note = note,
        })
      end
    end
  end
  return out
end

function Store:refresh(buf)
  buf = I.bufnr(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  local diags = {}
  for _, it in ipairs(self:items(buf)) do
    diags[#diags + 1] = {
      lnum = it.row - 1, col = it.col, end_lnum = it.end_row - 1, end_col = it.end_col,
      severity = self.o.severity[it.severity] or vim.diagnostic.severity.INFO,
      message = self.o.message(it), source = self.o.source, code = it.category,
    }
  end
  vim.diagnostic.set(self.ns_diag, buf, diags)
end

function Store:clear(buf)
  buf = I.bufnr(buf)
  self.B[buf] = nil
  api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  vim.diagnostic.reset(self.ns_diag, buf)
end

local function overlaps(a, b)
  return not (a[3] < b[1] or (a[3] == b[1] and a[4] <= b[2]) or a[1] > b[3] or (a[1] == b[3] and a[2] >= b[4]))
end

--- Anchor findings for `paras` (replacing earlier ones in those paragraphs).
--- `by_para[p.id]` is a list of findings { quote, suggestions, issue, category,
--- severity, ... }. Returns the number anchored.
function Store:anchor(buf, paras, by_para)
  buf = I.bufnr(buf)
  self.B[buf] = self.B[buf] or { items = {} }
  local st = self.B[buf]
  local function in_scope(row)
    for _, p in ipairs(paras) do
      if row >= p.srow and row <= p.erow then return true end
    end
  end
  local keep = {}
  for _, f in ipairs(st.items) do
    local m = api.nvim_buf_get_extmark_by_id(buf, self.ns, f.mark, {})
    if m[1] and not in_scope(m[1] + 1) then
      keep[#keep + 1] = f
    else
      pcall(api.nvim_buf_del_extmark, buf, self.ns, f.mark)
    end
  end
  st.items = keep

  local dis, n = get_dismissed(), 0
  for _, p in ipairs(paras) do
    local taken, last = {}, {}
    for _, f in ipairs(by_para[p.id] or {}) do
      f.suggestions = vim.tbl_filter(function(s)
        return type(s) == "string" and s ~= "" and norm(s) ~= norm(f.quote)
      end, type(f.suggestions) == "table" and f.suggestions or {})
      local r1, c1, r2, c2, be = prose.locate(p, f.quote, last[f.quote])
      if r1 then
        last[f.quote] = be
        local range = { r1, c1, r2, c2 }
        local clash = false
        for _, t in ipairs(taken) do
          if overlaps(range, t) and (not self.o.overlap or (t[1] == r1 and t[2] == c1 and t[3] == r2 and t[4] == c2 and t.issue == f.issue)) then
            clash = true
            break
          end
        end
        f.key = self:dismiss_key(f)
        if not clash and not (self.o.need_fix and #f.suggestions == 0) and not dis[f.key] then
          range.issue = f.issue
          taken[#taken + 1] = range
          f.mark = api.nvim_buf_set_extmark(buf, self.ns, r1 - 1, c1, {
            end_row = r2 - 1, end_col = c2, right_gravity = false, end_right_gravity = true,
          })
          f.p = p.id
          f.suggestions = vim.list_slice(f.suggestions, 1, 3)
          st.items[#st.items + 1] = f
          n = n + 1
        end
      end
    end
  end
  self:refresh(buf)
  return n
end

--- Walker key: dismiss the finding for good (undoable).
function Store:dismiss_action()
  return function(S, it, W)
    local k = it.key
    local f = self.B[S.buf].items[it.idx]
    get_dismissed()[k] = true
    I.save(I.json_file("state", "dismissed.json"), dismissed)
    f.dismissed = true
    W.push({
      kind = "dismissed",
      undo = function()
        dismissed[k] = nil
        I.save(I.json_file("state", "dismissed.json"), dismissed)
        f.dismissed = false
      end,
    })
    W.step()
  end
end

--- The finding behind a walker item.
function Store:finding(buf, it) return self.B[I.bufnr(buf)].items[it.idx] end

--- Walker source field: the identity "later" remembers an item by.
function Store.later_key(_, it) return it.key end

--- The deferred items of `buf` across every store, as quickfix entries.
function I.later_items(buf)
  buf = I.bufnr(buf)
  local set, out = I.later(), {}
  for _, s in ipairs(stores) do
    for _, it in ipairs(s:items(buf)) do
      if set[it.key] then
        out[#out + 1] = {
          bufnr = buf, lnum = it.row, col = it.col + 1, end_lnum = it.end_row, end_col = it.end_col + 1,
          text = s.o.source .. ": " .. s.o.message(it):gsub("\n", " "),
        }
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- talk: discuss a finding, get a new suggestion

local TALK_SYSTEM = [[
You are the editor who made a finding about a passage of the author's draft, now discussing it with the author. Reply to the author's latest message honestly and briefly (under sixty words): explain, concede when they are right, or adjust your advice. Don't flatter.

suggestion: a new replacement for exactly the passage at issue that takes the conversation into account, keeping its markup, citations and language. Give one whenever a change to the text still makes sense, including when the author asks for a different kind of change. Give "" only when you now agree the passage should stay as written.]]

local TALK_SCHEMA = {
  type = "object",
  properties = { reply = { type = "string" }, suggestion = { type = "string" } },
  required = { "reply", "suggestion" },
  additionalProperties = false,
}

local function talk_prompt(buf, it, f, msg)
  local p = prose.at(prose.paragraphs(buf), it.row)
  local guide = prose.profile(buf)
  local parts = { "Language: " .. prose.language(buf) .. "." }
  if guide then parts[#parts + 1] = "\nThe author's style guide:\n<style_guide>\n" .. guide .. "\n</style_guide>" end
  parts[#parts + 1] = "\n<paragraph>\n" .. (p and p.text or it.text) .. "\n</paragraph>"
  parts[#parts + 1] = "\nPassage at issue:\n<passage>" .. it.text .. "</passage>"
  parts[#parts + 1] = "\nYour finding: " .. (f.issue or "")
  if f.rule then parts[#parts + 1] = "Rule: " .. f.rule end
  if f.fix then parts[#parts + 1] = "Suggested fix: " .. f.fix end
  if #f.suggestions > 0 then
    parts[#parts + 1] = "Your current suggestions:"
    for i, s in ipairs(f.suggestions) do parts[#parts + 1] = ("%d. %s"):format(i, s) end
  end
  parts[#parts + 1] = "\nConversation:"
  for _, t in ipairs(f.talk or {}) do
    parts[#parts + 1] = "Author: " .. t.user
    parts[#parts + 1] = "You: " .. t.reply
  end
  parts[#parts + 1] = "Author: " .. msg
  return table.concat(parts, "\n")
end

--- Walker key: talk about the finding. The reply shows in the float; a new
--- suggestion becomes 1 (the earlier ones follow). `u` takes it back.
function Store:talk_action()
  return function(S, it, W)
    local f = self:finding(S.buf, it)
    vim.ui.input({ prompt = "Talk: " }, function(msg)
      if not msg or vim.trim(msg) == "" or not f then return end
      local c = require("writing.config").task("talk")
      vim.notify("Thinking…", vim.log.levels.INFO, { title = S.title })
      require("writing.claude").run({
        prompt = talk_prompt(S.buf, it, f, msg), system = TALK_SYSTEM, schema = TALK_SCHEMA,
        model = c.model, effort = c.effort,
      }, function(err, res)
        if err then return vim.notify(err, vim.log.levels.ERROR, { title = S.title }) end
        local before = { suggestions = f.suggestions, talk = f.talk }
        f.talk = vim.list_extend(vim.deepcopy(f.talk or {}), { { user = msg, reply = res.reply or "" } })
        local new = res.suggestion
        if type(new) == "string" and new ~= "" and norm(new) ~= norm(f.quote) then
          local rest = vim.tbl_filter(function(s) return s ~= new end, f.suggestions)
          f.suggestions = vim.list_slice(vim.list_extend({ new }, rest), 1, 4)
        end
        -- still walking this finding: record it (for `u`) and show it
        local cur = W.current()
        if cur == S and not S.paused and S.issue and S.issue.idx == it.idx then
          W.push({ kind = "discussed", undo = function() f.suggestions, f.talk = before.suggestions, before.talk end })
          W.step()
        else
          vim.notify("Reply ready: " .. (res.reply or ""), vim.log.levels.INFO, { title = S.title })
        end
      end)
    end)
  end
end

return I
