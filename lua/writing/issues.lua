-- Quote-anchored issues, shared by the grammar audit and the rigor review.
--
-- Claude answers with verbatim quotes per paragraph; `store:anchor()` finds
-- each in its paragraph (prose.locate), drops what isn't there (that's how
-- hallucinated findings die), and keeps the rest as extmarks, so they move
-- with your edits. `store:items()` returns only those whose current text still
-- equals the quote: fixed ones vanish and `u` (extmark undo_restore) brings
-- them back. Every store mirrors its items as diagnostics in its own
-- namespace, and remembers dismissals in stdpath("state")/writing.

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
        out[#out + 1] = vim.tbl_extend("force", f, {
          idx = idx, row = r1 + 1, col = c1, end_row = r2 + 1, end_col = c2, text = text,
          label = self.o.label(f), note = self.o.note(f),
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
        if not clash and not (self.o.need_fix and #f.suggestions == 0) and not dis[self:dismiss_key(f)] then
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
    local k = self:dismiss_key(it)
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

return I
