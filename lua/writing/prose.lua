-- The prose in a buffer, as paragraphs, plus what Claude needs to know about
-- it (language, style guide, glossary).
--
-- Paragraphs are runs of non-blank lines. What isn't prose is left out per
-- filetype: Markdown/Quarto front matter, fences and HTML comments; LaTeX's
-- preamble, comments and math/verbatim environments; Typst's #set/#show/
-- #import/#let lines, raw blocks and display math. Headings are paragraphs of
-- their own. The text is sent as written (markup included) with an instruction
-- to leave markup alone, and issues come back as verbatim quotes, which
-- `locate` finds in the paragraph with whitespace and line breaks collapsed.

local M = {}

local api = vim.api

local TEX_SKIP = {
  "equation", "align", "gather", "multline", "eqnarray", "flalign", "alignat", "math", "displaymath",
  "verbatim", "Verbatim", "lstlisting", "minted", "tikzpicture", "tabular", "array", "comment",
}

local function tex_skip_env(line)
  local env = line:match("\\begin{([%a]+)%*?}")
  if not env then return nil end
  for _, e in ipairs(TEX_SKIP) do
    if env == e then return env end
  end
end

-- Is `line` a heading (its own paragraph)?
local function heading(ft, line)
  if ft == "markdown" or ft == "quarto" or ft == "rmd" then return line:match("^#+%s") ~= nil end
  if ft == "tex" or ft == "plaintex" then
    return line:match("^%s*\\%a*section%*?[%[{]") ~= nil or line:match("^%s*\\chapter%*?[%[{]") ~= nil
      or line:match("^%s*\\paragraph%*?{") ~= nil
  end
  if ft == "typst" then return line:match("^%s*=+%s") ~= nil end
  return false
end

--- Paragraphs of `buf`: { id, srow, erow (1-based, inclusive), lines, text }.
function M.paragraphs(buf)
  local ft = vim.bo[buf].filetype
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local md = ft == "markdown" or ft == "quarto" or ft == "rmd"
  local tex = ft == "tex" or ft == "plaintex"
  local typ = ft == "typst"

  local out, cur = {}, nil
  local function flush()
    if cur then
      local text = table.concat(cur.lines, "\n")
      -- at least three words of letters, or it isn't worth a request
      local words = select(2, text:gsub("%a%a+", ""))
      if words >= 3 or (cur.heading and words >= 1) then
        cur.id = #out + 1
        cur.text = text
        out[#out + 1] = cur
      end
      cur = nil
    end
  end
  local function add(i, line)
    if not cur then cur = { srow = i, lines = {}, heading = false } end
    cur.lines[#cur.lines + 1] = line
    cur.erow = i
  end

  local skip_until -- a pattern that ends the current non-prose block
  local in_doc = not (tex and table.concat(lines, "\n"):find("\\begin{document}", 1, true))
  for i, line in ipairs(lines) do
    local blank = line:match("^%s*$") ~= nil
    if skip_until then
      if line:match(skip_until) then skip_until = nil end
      flush()
    elseif tex and not in_doc then
      if line:find("\\begin{document}", 1, true) then in_doc = true end
    elseif md and i == 1 and line:match("^%-%-%-%s*$") then
      skip_until = "^%-%-%-%s*$"
    elseif md and line:match("^%s*```") or md and line:match("^%s*~~~") then
      flush()
      skip_until = line:match("^%s*```") and "^%s*```%s*$" or "^%s*~~~%s*$"
    elseif md and line:match("^%s*<!%-%-") and not line:match("%-%->") then
      flush()
      skip_until = "%-%->"
    elseif tex and tex_skip_env(line) then
      flush()
      local env = tex_skip_env(line)
      if not line:find("\\end{" .. env, 1, true) then skip_until = "\\end{" .. env end
    elseif tex and (line:match("^%s*\\%[") or line:match("^%s*%$%$")) then
      flush()
      local close = line:match("^%s*\\%[") and "\\%]" or "%$%$"
      if not line:sub(3):find(close) then skip_until = close end
    elseif heading(ft, line) then
      flush()
      add(i, line)
      cur.heading = true
      flush()
    elseif tex and (line:match("^%s*%%") or line:match("^%s*\\(%a+)") and not line:match("%a%a%a.*%s%a%a%a")) then
      -- comments, and lines that are only commands (\label, \maketitle, ...)
      flush()
    elseif typ and (line:match("^%s*```")) then
      flush()
      skip_until = "^%s*```%s*$"
    elseif typ and line:match("^%s*#%a+") and (line:match("^%s*#set%s") or line:match("^%s*#show")
        or line:match("^%s*#import") or line:match("^%s*#let%s") or line:match("^%s*#include")) then
      flush()
    elseif typ and line:match("^%s*%$%s*$") then
      flush()
      skip_until = "^%s*%$%s*$"
    elseif ft == "gitcommit" and line:match("^#") then
      flush()
    elseif blank then
      flush()
    else
      add(i, line)
    end
  end
  flush()
  return out
end

--- Find `quote` in paragraph `p`, ignoring differences in whitespace. Returns
--- 1-based start row, 0-based start col, 1-based end row, exclusive end col.
--- `from` (a byte offset into p.text) finds a later occurrence.
function M.locate(p, quote, from)
  local text = p.text
  local norm, map, prev_space = {}, {}, true
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch:match("%s") then
      if not prev_space then
        norm[#norm + 1] = " "
        map[#norm] = i
      end
      prev_space = true
    else
      norm[#norm + 1] = ch
      map[#norm] = i
      prev_space = false
    end
  end
  local ntext = table.concat(norm)
  local q = vim.trim((quote or ""):gsub("%s+", " "))
  if q == "" then return nil end
  local nfrom = 1
  if from then
    for k = 1, #norm do
      if map[k] > from then nfrom = k break end
      nfrom = #norm + 1
    end
  end
  local s, e = ntext:find(q, nfrom, true)
  if not s then return nil end
  local bs, be = map[s], map[e] -- 1-based inclusive byte offsets into p.text

  -- byte offset -> (row, col)
  local function pos(off)
    local acc = 0
    for k, l in ipairs(p.lines) do
      if off <= acc + #l + 1 then return p.srow + k - 1, off - acc - 1 end
      acc = acc + #l + 1
    end
    return p.erow, #p.lines[#p.lines]
  end
  local r1, c1 = pos(bs)
  local r2, c2 = pos(be)
  return r1, c1, r2, c2 + 1, be
end

local LANG = {
  en = "English", es = "Spanish", fr = "French", de = "German", pt = "Portuguese", it = "Italian",
  ca = "Catalan", nl = "Dutch",
}

--- The buffer's languages, from 'spelllang' ("es,en" -> "Spanish or English").
function M.language(buf)
  local win = vim.fn.bufwinid(buf)
  local sl = win ~= -1 and vim.wo[win].spell and vim.bo[buf].spelllang or vim.bo[buf].spelllang
  local names = {}
  for code in (sl or "en"):gmatch("[^,]+") do
    local base = code:match("^(%a%a)")
    local region = code:match("^%a%a_(%a%a)")
    local name = LANG[base] or code
    if region then name = name .. " (" .. region:upper() .. ")" end
    if not vim.tbl_contains(names, name) then names[#names + 1] = name end
  end
  return table.concat(names, " or ")
end

local warned_legacy = false

--- Your style guide, sent with every request (audience, register, conventions,
--- terms to leave alone) and the rulebook of :Writing conform: the
--- `style_guide` option, by default the nearest STYLE.md (or the older
--- .nvim/writing.md) above the file. Returns its text and path.
function M.profile(buf)
  local opt = require("writing.config").options.style_guide
  if not opt then return nil, nil end
  if type(opt) == "function" then return opt(buf) end
  local names = type(opt) == "table" and opt or { opt }
  local name = api.nvim_buf_get_name(buf)
  local dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  -- The nearest directory wins; within one, the list's order. (A name can
  -- have a directory part, so compare the directory it was found from.)
  local found = vim.fs.find(names, { upward = true, path = dir, type = "file", limit = math.huge })
  local f, best
  for _, n in ipairs(names) do
    for _, path in ipairs(found) do
      local base = path:sub(-#n - 1) == "/" .. n and path:sub(1, -#n - 2)
      if base and (not best or #base > #best) then f, best = path, base end
    end
  end
  if not f then return nil, nil end
  if not warned_legacy and f:find("/%.nvim/writing%.md$") then
    warned_legacy = true
    vim.notify(("Using %s. Move it to STYLE.md at the project root so collaborators see it too.")
      :format(vim.fn.fnamemodify(f, ":~:.")), vim.log.levels.INFO, { title = "Writing" })
  end
  return table.concat(vim.fn.readfile(f), "\n"), f
end

--- Words from the 'spellfile' (zg): never "correct" them.
function M.glossary(buf)
  local words = {}
  for f in (vim.bo[buf].spellfile ~= "" and vim.bo[buf].spellfile or vim.o.spellfile):gmatch("[^,]+") do
    if vim.fn.filereadable(f) == 1 then
      for _, l in ipairs(vim.fn.readfile(f)) do
        if l ~= "" and not l:match("^#") then words[#words + 1] = l:gsub("/.*", "") end
      end
    end
  end
  -- also the default spellfile location when 'spellfile' is empty
  if #words == 0 then
    for _, f in ipairs(vim.fn.glob(vim.fn.stdpath("config") .. "/spell/*.add", false, true)) do
      for _, l in ipairs(vim.fn.readfile(f)) do
        if l ~= "" and not l:match("^#") then words[#words + 1] = l:gsub("/.*", "") end
      end
    end
  end
  return vim.list_slice(words, 1, 300)
end

--- The paragraph containing `row`, if any.
function M.at(paras, row)
  for _, p in ipairs(paras) do
    if row >= p.srow and row <= p.erow then return p end
  end
end

return M
