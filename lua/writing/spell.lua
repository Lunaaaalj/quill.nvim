-- Spell audit: walk every spelling issue in the buffer, one at a time, in a
-- float under the word, jumping to the next one after each action.
--
--   1-9 / <CR>   replace with that suggestion (<CR>: the one under the cursor)
--   R            replace every occurrence of the word with it
--   e            type the replacement yourself
--   s / <Space>  skip this one          S  ignore the word (this session)
--   l            leave it for later (comes back next time, after the rest;
--                editing its line makes it a fresh issue again)
--   a            add the word to your spellfile (zg)
--   u            undo the last action and go back to it
--   q / <Esc>    stop (`:SpellAudit` again resumes)
--
-- Issues are found with `]s` + spellbadword(), not by checking strings, so
-- they are exactly what `]s` visits: syntax/treesitter @nospell regions (code
-- blocks, LaTeX commands) are left out. The float, skips and undo are the
-- shared walker's (walker.lua), which rescans after every
-- action, so edits never leave stale positions.

local W = require("writing.walker")

local M = {}

local api = vim.api

local KIND = { bad = "misspelled", caps = "capitalise", rare = "rare word", ["local"] = "other region" }

-- Every issue `]s` would visit in `win`.
local function issues(S)
  return api.nvim_win_call(S.win, function()
    local view, wrapscan = vim.fn.winsaveview(), vim.o.wrapscan
    vim.o.wrapscan = false
    local out = {}
    -- spellbadword(): the bad word under or after the cursor, in its line only.
    local function here()
      local r = vim.fn.spellbadword()
      if r[1] == "" then return false end
      local p = api.nvim_win_get_cursor(0)
      out[#out + 1] = {
        row = p[1], col = p[2], end_row = p[1], end_col = p[2] + #r[1],
        text = r[1], kind = r[2], label = KIND[r[2]] or r[2],
      }
      return true
    end
    api.nvim_win_set_cursor(0, { 1, 0 })
    here() -- `]s` from here would step over a word at the very start
    while true do
      local before = api.nvim_win_get_cursor(0)
      vim.cmd("silent! normal! ]s")
      local p = api.nvim_win_get_cursor(0)
      if (p[1] == before[1] and p[2] == before[2]) or not here() then break end
    end
    vim.o.wrapscan = wrapscan
    vim.fn.winrestview(view)
    return out
  end)
end

-- "Later" identity: the word in its line (whitespace collapsed).
local function later_key(S, it)
  local line = api.nvim_buf_get_lines(S.buf, it.row - 1, it.row, false)[1] or ""
  return "spell\31" .. it.text .. "\31" .. require("writing.issues").norm(line)
end

local function suggestions(S, it)
  return api.nvim_win_call(S.win, function()
    return vim.fn.spellsuggest(it.text, require("writing.config").options.spell.suggestions, it.kind == "caps")
  end)
end

-- Whole-word, case-sensitive, using 'iskeyword' (so accented letters count).
local function replace_all(S, it)
  local text = W.selected() or S.sugg[1]
  if not text then return end
  local re = vim.regex("\\V\\C\\<" .. vim.fn.escape(it.text, "\\") .. "\\>")
  local n, before = 0, W.checkpoint()
  for lnum = 0, api.nvim_buf_line_count(S.buf) - 1 do
    local hits, start = {}, 0
    while true do
      local s, e = re:match_line(S.buf, lnum, start)
      if not s then break end
      hits[#hits + 1] = { start + s, start + e }
      start = start + e
    end
    for i = #hits, 1, -1 do
      api.nvim_buf_set_text(S.buf, lnum, hits[i][1], lnum, hits[i][2], { text })
      n = n + 1
    end
  end
  W.push({ kind = "fixed", change = before, n = n })
  W.step()
end

-- spellgood/spellundo run in the edited window: the float has 'spell' off and
-- its own 'spelllang'.
local function spell_cmd(S, cmd, word)
  api.nvim_win_call(S.win, function() vim.cmd("silent " .. cmd .. " " .. vim.fn.fnameescape(word)) end)
end

local function ignore(S, it)
  spell_cmd(S, "spellgood!", it.text)
  W.push({ kind = "ignored", undo = function(s) spell_cmd(s, "spellundo!", it.text) end })
  W.step()
end

local function add(S, it)
  spell_cmd(S, "spellgood", it.text)
  W.push({ kind = "added", undo = function(s) spell_cmd(s, "spellundo", it.text) end })
  W.step()
end

--- Start (or resume) the audit of the current window's buffer.
function M.start()
  local win = api.nvim_get_current_win()
  if vim.bo.buftype ~= "" and not (W.current() and W.current().key == "spell") then
    return vim.notify("Not a file buffer", vim.log.levels.WARN, { title = "Spell audit" })
  end
  W.start({
    key = "spell", title = "Spell", win = win,
    issues = issues, suggestions = suggestions, later_key = later_key,
    keys = {
      { "R", "replace every occurrence", replace_all },
      { "S", "ignore word this session", ignore },
      { "a", "add word to spellfile", add },
    },
    footer = " 1-9 fix · R all · e edit · s skip · l later · S ignore · a add · u undo · q quit ",
    empty = "No spelling issues", resume_hint = require("writing").hint("<Plug>(SpellAudit)", ":SpellAudit"),
    on_start = function(S)
      S.spell_was = vim.wo[S.win].spell
      vim.wo[S.win].spell = true
    end,
    on_finish = function(S, stopped)
      if not stopped and api.nvim_win_is_valid(S.win) then vim.wo[S.win].spell = S.spell_was end
    end,
  })
end

--- The spelling issues of `buf` left for later, as quickfix entries (scans the
--- current window, which must show `buf`).
function M.later_items(buf)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= buf then return {} end
  local set = require("writing.issues").later()
  local was = vim.wo[win].spell
  vim.wo[win].spell = true
  local S = { win = win, buf = buf }
  local out = {}
  for _, it in ipairs(issues(S)) do
    if set[later_key(S, it)] then
      out[#out + 1] = { bufnr = buf, lnum = it.row, col = it.col + 1, end_lnum = it.row, end_col = it.end_col + 1,
        text = "spell: " .. it.text .. " (" .. it.label .. ")" }
    end
  end
  vim.wo[win].spell = was
  return out
end

return M
