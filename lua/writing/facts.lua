-- What a suggestion may not invent. Claude's rewrites must not add numbers,
-- citations or placeholders the author never wrote: when a rule asks to
-- "quantify" and the text has no figure, a model will happily write "X%" or
-- make one up. Like a quote that isn't in its paragraph, that is checked
-- here, not trusted to the prompt.
--
--   facts(text)              what `text` contains: numbers (number words
--                            count: "three" = 3), citation keys, placeholders
--   invented(sugg, known)    what `sugg` adds that `known` doesn't have, as
--                            short labels ({ "37", "@smith2020", "X" }); empty
--                            when it's clean
--   lost(orig, rewrite)      markup of `orig` (citations, refs, labels, math,
--                            code, URLs) missing from `rewrite`

local M = {}

local WORDS = {
  zero = 0, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
  eleven = 11, twelve = 12, thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16, seventeen = 17,
  eighteen = 18, nineteen = 19, twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60,
  seventy = 70, eighty = 80, ninety = 90, hundred = 100, thousand = 1000, million = 1000000,
  -- not "one": it's a pronoun far more often than a number
  dos = 2, tres = 3, cuatro = 4, cinco = 5, seis = 6, siete = 7, ocho = 8, nueve = 9, diez = 10,
}

-- Placeholder-ish bracket contents.
local HOLES = { "number", "amount", "value", "figure", "date", "name", "citation", "source", "percentage",
  "year", "ref", "cite", "insert", "n", "x" }

-- Spaces that group thousands: "1 200", with a no-break or (narrow) thin space.
local GROUP_SPACES = { " ", "\194\160", "\226\128\175", "\226\128\137" }

-- A number's identity is its digits, whatever the separators: 3,5 = 3.5 and
-- 1.200 = 1,200 = 1 200, so a suggestion that only changes the decimal or
-- thousands separator (or the locale's convention) brings in nothing new.
local function num_key(digits)
  return "#" .. (digits:gsub("^0+(%d)", "%1"))
end

local function numbers(text, out)
  for _, sp in ipairs(GROUP_SPACES) do
    -- join "1 200 000" into one number (only groups of exactly three digits)
    local prev
    repeat
      prev = text
      text = text:gsub("(%d)" .. sp .. "(%d%d%d)%f[%D]", "%1%2")
    until text == prev
  end
  -- digits, with thousands separators and decimals: 1,200 / 3.5 / 3,5 / 12
  for n in text:gmatch("%d[%d,%.]*") do
    n = n:gsub("[,%.]+$", "")
    out[num_key((n:gsub("[,%.]", "")))] = n
  end
  for w in text:gmatch("%a+") do
    local v = WORDS[w:lower()]
    if v then out[num_key(tostring(v))] = w end
  end
end

local function citations(text, out)
  -- \cite{a,b}, \citep[p. 3]{a}, \autocite*{a}
  for keys in text:gmatch("\\%a*cite%a*%*?[^{}\n]-{([^}]*)}") do
    for k in keys:gmatch("[^,%s]+") do out["@" .. k] = "@" .. k end
  end
  -- Pandoc/Typst @key, not inside an e-mail address
  for pre, k in text:gmatch("()@([%w_][%w_:%-%./]*)") do
    local before = pre > 1 and text:sub(pre - 1, pre - 1) or " "
    if not before:match("[%w]") then
      k = k:gsub("[%.:]+$", "")
      out["@" .. k] = "@" .. k
    end
  end
  -- Typst #cite(<key>)
  for k in text:gmatch("#cite%(<([^>]+)>") do out["@" .. k] = "@" .. k end
end

local function placeholders(text, out)
  -- a lone capital X/Y/Z/N (not X-ray, not part of a word or formula like N=)
  for pre, l, post in text:gmatch("()%f[%w]([XYZN])%f[%W]()") do
    local nxt = text:sub(post, post)
    local prev = pre > 1 and text:sub(pre - 1, pre - 1) or " "
    if nxt ~= "-" and prev ~= "-" and not text:sub(post):match("^%s*=") then
      out["?" .. l] = l
    end
  end
  for h in text:gmatch("X[X]+") do out["?" .. h] = h end
  for _, h in ipairs({ "TBD", "TODO", "??", "[...]", "[…]", "<...>", "⟨…⟩" }) do
    if text:find(h, 1, true) then out["?" .. h] = h end
  end
  for inner in text:gmatch("%[([^%]\n]+)%]") do
    local lw = inner:lower()
    if not inner:match("^[@%^]") then
      for _, w in ipairs(HOLES) do
        if lw:match("%f[%a]" .. w .. "%f[%A]") and #inner <= 30 then out["?[" .. inner .. "]"] = "[" .. inner .. "]" end
      end
    end
  end
  for inner in text:gmatch("<([%a ]+)>") do
    local lw = inner:lower()
    for _, w in ipairs(HOLES) do
      if lw:match("%f[%a]" .. w .. "%f[%A]") then out["?<" .. inner .. ">"] = "<" .. inner .. ">" end
    end
  end
end

--- What `text` contains (a set: key -> label).
function M.facts(text)
  local out = {}
  numbers(text or "", out)
  citations(text or "", out)
  placeholders(text or "", out)
  return out
end

--- What `sugg` brings in that `known` (a facts() set, or text) doesn't have.
function M.invented(sugg, known)
  if type(known) == "string" then known = M.facts(known) end
  local got, out = M.facts(sugg), {}
  for k, label in pairs(got) do
    -- what the author wrote (their own "TODO", a figure) is theirs to reuse
    if not known[k] then out[#out + 1] = label end
  end
  table.sort(out)
  return out
end

local MARKUP = {
  "\\%a*cite%a*%*?[^{}\n]-%b{}", "\\%a*ref%*?%b{}", "\\label%b{}", "\\url%b{}", "\\href%b{}",
  "%$%$.-%$%$", "%f[%$]%$[^%$\n]+%$", "`[^`\n]+`", "https?://[^%s%)%]>]+", "%[@[^%]]+%]", "#cite%(<[^>]+>%)",
  "%]%([^%)]+%)",
}

--- Markup of `orig` that `rewrite` dropped (whitespace-insensitive).
function M.lost(orig, rewrite)
  local function squash(s) return (s:gsub("%s+", "")) end
  local r = squash(rewrite or "")
  local out = {}
  for _, pat in ipairs(MARKUP) do
    for m in (orig or ""):gmatch(pat) do
      if not r:find(squash(m), 1, true) then out[#out + 1] = m end
    end
  end
  return out
end

return M
