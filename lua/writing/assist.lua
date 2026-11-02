-- Selection tools and the companion chat.
--
--   rewrite   the selection (or the paragraph under the cursor), following an
--             instruction you pick; the result shows in a float under it:
--             <CR>/a accept, r try again, q cancel. Accepting is one undo step.
--   ask       a question about the selection/paragraph, answered with the
--             whole document as context, in a float.
--   chat      a Claude chat in a split (the `chat` option, else `:terminal
--             claude`), primed to read the file and act as your companion.

local prose = require("writing.prose")
local claude = require("writing.claude")

local M = {}

local function cfg(o) return require("writing.config").task("assist", o) end

local api = vim.api
local ns = api.nvim_create_namespace("writing_assist")

-- The target range: `visual` true = the last visual selection, { r1, r2 } =
-- those lines (1-based, inclusive), else the paragraph under the cursor.
-- Returns { buf, r1, c1, r2, c2 (0-based, end exclusive) } and its text.
local function target(visual)
  local buf = api.nvim_get_current_buf()
  if type(visual) == "table" then
    local r1, r2 = visual[1] - 1, visual[2] - 1
    local c2 = #(api.nvim_buf_get_lines(buf, r2, r2 + 1, false)[1] or "")
    local text = table.concat(api.nvim_buf_get_text(buf, r1, 0, r2, c2, {}), "\n")
    return { buf = buf, r1 = r1, c1 = 0, r2 = r2, c2 = c2 }, text
  end
  if visual then
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local mode = vim.fn.visualmode()
    local r1, c1, r2, c2 = s[2] - 1, s[3] - 1, e[2] - 1, e[3]
    if mode == "V" then
      c1 = 0
      c2 = #(api.nvim_buf_get_lines(buf, r2, r2 + 1, false)[1] or "")
    else
      local last = api.nvim_buf_get_lines(buf, r2, r2 + 1, false)[1] or ""
      -- '> is the last character's first byte (huge after `$`); include all of it
      c2 = math.min(c2, #last)
      if c2 >= 1 then c2 = c2 + vim.str_utf_end(last, c2) end
    end
    local text = table.concat(api.nvim_buf_get_text(buf, r1, c1, r2, c2, {}), "\n")
    return { buf = buf, r1 = r1, c1 = c1, r2 = r2, c2 = c2 }, text
  end
  local p = prose.at(prose.paragraphs(buf), api.nvim_win_get_cursor(0)[1])
  if not p then return nil end
  local last = api.nvim_buf_get_lines(buf, p.erow - 1, p.erow, false)[1]
  return { buf = buf, r1 = p.srow - 1, c1 = 0, r2 = p.erow - 1, c2 = #last }, p.text
end

local function document(buf)
  local t = {}
  for _, p in ipairs(prose.paragraphs(buf)) do t[#t + 1] = p.text end
  return table.concat(t, "\n\n")
end

local function float(lines, o)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = o.filetype or "writingassist"
  local width = math.min(o.width or 80, vim.o.columns - 4)
  local height = 0
  for _, l in ipairs(lines) do height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width)) end
  height = math.min(height, math.floor(vim.o.lines * 0.6))
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = math.max(height, 1),
    border = "rounded", style = "minimal", title = o.title, title_pos = "left",
    footer = o.footer, footer_pos = "center", zindex = 60,
  })
  vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].winblend = true, true, 0
  vim.wo[win].winhighlight = "FloatTitle:WritingTitle,FloatFooter:WritingMuted"
  vim.keymap.set("n", "q", function() api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
  return buf, win
end

-- ---------------------------------------------------------------------------
-- rewrite

local REWRITE_SYSTEM = [[
You are an editor. Rewrite the passage following the instruction.
- Keep the meaning, and keep every citation, reference, label, math, code, command and markup exactly as written.
- Keep the passage's language unless the instruction is to translate.
- Keep its line structure where it makes sense (a one-line passage stays one line).
- rewrite: only the new passage. note: one short sentence on what you changed.]]

local REWRITE_SCHEMA = {
  type = "object",
  properties = { rewrite = { type = "string" }, note = { type = "string" } },
  required = { "rewrite", "note" },
  additionalProperties = false,
}

local function run_rewrite(range, text, instruction, c)
  -- anchor the range so edits elsewhere while waiting don't misplace it
  local mark = api.nvim_buf_set_extmark(range.buf, ns, range.r1, range.c1, {
    end_row = range.r2, end_col = range.c2, right_gravity = false, end_right_gravity = true,
  })
  vim.notify("Rewriting (" .. instruction:lower() .. ")…", vim.log.levels.INFO, { title = "Writing" })
  claude.run({
    prompt = ("Language: %s.\nInstruction: %s\n\n<passage>\n%s\n</passage>"):format(
      prose.language(range.buf), instruction, text),
    system = REWRITE_SYSTEM, schema = REWRITE_SCHEMA, model = c.model, effort = c.effort,
  }, function(err, res)
    if err then
      pcall(api.nvim_buf_del_extmark, range.buf, ns, mark)
      return vim.notify(err, vim.log.levels.ERROR, { title = "Writing" })
    end
    local lines = vim.split(res.rewrite, "\n")
    local shown = vim.list_extend(vim.deepcopy(lines), { "", "— " .. res.note })
    -- facts the rewrite made up (numbers, citations, placeholders): say so
    local facts = require("writing.facts")
    local inv = facts.invented(res.rewrite,
      table.concat(api.nvim_buf_get_lines(range.buf, 0, -1, false), "\n") .. "\n" .. instruction)
    local lost = facts.lost(text, res.rewrite)
    local warn = {}
    if #inv > 0 then warn[#warn + 1] = "⚠ made up, not in your text: " .. table.concat(inv, ", ") end
    if #lost > 0 then warn[#warn + 1] = "⚠ dropped: " .. table.concat(lost, ", ") end
    vim.list_extend(shown, warn)
    local fbuf, fwin = float(shown, {
      title = " Rewrite · " .. instruction .. " ", footer = " <CR>/a accept · r retry · q cancel ",
      filetype = vim.bo[range.buf].filetype == "" and "writingassist" or vim.bo[range.buf].filetype,
    })
    api.nvim_buf_set_extmark(fbuf, ns, #lines + 1, 0, { end_row = #lines + 2, hl_group = "WritingMuted" })
    for i = 1, #warn do
      api.nvim_buf_set_extmark(fbuf, ns, #lines + 1 + i, 0, { end_row = #lines + 2 + i, hl_group = "WritingFlag" })
    end
    vim.wo[fwin].spell = false
    local function close()
      if api.nvim_win_is_valid(fwin) then api.nvim_win_close(fwin, true) end
    end
    -- read the range before closing: wiping the float deletes the mark
    local function accept()
      local m = api.nvim_buf_get_extmark_by_id(range.buf, ns, mark, { details = true })
      close()
      pcall(api.nvim_buf_del_extmark, range.buf, ns, mark)
      if not m[1] then return end
      api.nvim_buf_call(range.buf, function() vim.cmd("let &l:undolevels = &l:undolevels") end)
      api.nvim_buf_set_text(range.buf, m[1], m[2], m[3].end_row, m[3].end_col, lines)
    end
    local o = { buffer = fbuf, nowait = true }
    vim.keymap.set("n", "<CR>", accept, o)
    vim.keymap.set("n", "a", accept, o)
    vim.keymap.set("n", "r", function()
      local m = api.nvim_buf_get_extmark_by_id(range.buf, ns, mark, { details = true })
      close()
      pcall(api.nvim_buf_del_extmark, range.buf, ns, mark)
      if m[1] then
        run_rewrite({ buf = range.buf, r1 = m[1], c1 = m[2], r2 = m[3].end_row, c2 = m[3].end_col }, text, instruction, c)
      end
    end, o)
    api.nvim_create_autocmd("BufWipeout", {
      buffer = fbuf, once = true,
      callback = function() pcall(api.nvim_buf_del_extmark, range.buf, ns, mark) end,
    })
  end)
end

--- `o.model` / `o.effort` override the configured ones (as for every pass).
function M.rewrite(visual, o)
  local range, text = target(visual)
  if not range then return vim.notify("No paragraph here", vim.log.levels.WARN, { title = "Writing" }) end
  local c = cfg(o)
  local items = vim.list_extend(vim.deepcopy(c.presets), { "Custom…" })
  vim.ui.select(items, { prompt = "Rewrite" }, function(choice)
    if not choice then return end
    if choice == "Custom…" then
      vim.ui.input({ prompt = "Rewrite instruction: " }, function(ins)
        if ins and ins ~= "" then run_rewrite(range, text, ins, c) end
      end)
    else
      run_rewrite(range, text, choice, c)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- ask

local ASK_SYSTEM = [[
You are a thoughtful writing companion: an honest, specific reader of the author's draft. Answer the author's question about the marked passage, using the whole document as context. Be concise and concrete: quote the text you refer to, and suggest specific wording when it helps. Answer in the language of the question. Plain Markdown.]]

function M.ask(visual, o)
  local range, text = target(visual)
  local c = cfg(o)
  if not range then return vim.notify("No paragraph here", vim.log.levels.WARN, { title = "Writing" }) end
  vim.ui.input({ prompt = "Ask about this passage: " }, function(q)
    if not q or q == "" then return end
    vim.notify("Thinking…", vim.log.levels.INFO, { title = "Writing" })
    local profile = prose.profile(range.buf)
    local prompt = ("Language: %s.\n%s\n<document>\n%s\n</document>\n\n<passage>\n%s\n</passage>\n\nQuestion: %s"):format(
      prose.language(range.buf),
      profile and ("<style_guide>\n" .. profile .. "\n</style_guide>\n") or "",
      document(range.buf), text, q)
    claude.run({ prompt = prompt, system = ASK_SYSTEM, model = c.model, effort = c.effort },
      function(err, answer)
        if err then return vim.notify(err, vim.log.levels.ERROR, { title = "Writing" }) end
        local _, win = float(vim.split(vim.trim(answer), "\n"),
          { title = " " .. q .. " ", footer = " q close ", filetype = "markdown", width = 90 })
        vim.wo[win].conceallevel = 2
      end)
  end)
end

-- ---------------------------------------------------------------------------
-- chat

function M.chat()
  local buf = api.nvim_get_current_buf()
  local file = api.nvim_buf_get_name(buf)
  if file == "" then return vim.notify("Save the file first", vim.log.levels.WARN, { title = "Writing" }) end
  local _, guide = prose.profile(buf)
  local prompt = table.concat({
    ("I'm writing %s (in %s)."):format(file, prose.language(buf)),
    "Be my writing companion: read the file, then tell me in two or three sentences what it argues and the one thing you'd work on first.",
    "After that, answer my questions about it. Be an honest, specific reader. Don't edit any file unless I ask you to.",
    guide and ("My style guide is %s; read it too."):format(guide) or nil,
  }, " ")
  local w = cfg().chat_width
  if w < 1 then w = math.floor(vim.o.columns * w) end
  vim.cmd("botright vertical " .. math.max(60, w) .. "split")
  local ctx = { buf = buf, file = file, win = api.nvim_get_current_win() }
  local hook = require("writing.config").options.chat
  if hook then return hook(prompt, ctx) end
  local tbuf = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(ctx.win, tbuf)
  local cmd = { require("writing.config").options.claude.command, prompt }
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart(cmd, { term = true })
  else
    vim.fn.termopen(cmd)
  end
  vim.cmd("startinsert")
end

return M
