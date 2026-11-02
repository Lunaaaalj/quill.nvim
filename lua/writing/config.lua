-- Defaults, merged with setup() opts into M.options. A pass resolves its
-- options once per run with M.task(name, o): setup() options, then the
-- session overrides from `:Writing model`, then a per-run `model=`/`effort=`.

local M = {}

M.defaults = {
  -- Headless Claude Code (`<command> -p --output-format json`), with your
  -- Claude Code login. Never `--bare`: it skips keychain reads, i.e. the login.
  claude = {
    command = "claude",
    -- extra CLI args added to every request
    args = {},
    timeout = 180000, -- ms per request
    max_jobs = 3, -- concurrent requests
  },
  -- Per pass: the model and --effort sent to claude.
  grammar = {
    model = "haiku",
    effort = "low",
    chunk_chars = 6000, -- paragraphs per request, by size
  },
  -- STYLE.md conformance: following a rulebook needs more than haiku
  conform = { model = "sonnet", effort = "medium", chunk_chars = 6000 },
  -- STYLE.md paragraph rewrites (rewrite for every paragraph)
  restyle = { model = "sonnet", effort = "medium", chunk_chars = 4000 },
  -- `t` in the walker: discuss a finding, get a new suggestion
  talk = { model = "sonnet", effort = "low" },
  outline = { model = "haiku", effort = "high", width = 60 },
  rigor = { model = "haiku", effort = "high", width = 64 },
  assist = {
    model = "haiku",
    effort = "medium",
    -- instructions offered by rewrite (plus "Custom…")
    presets = {
      "More concise",
      "More formal / academic",
      "Simpler and plainer",
      "Active voice",
      "Smoother flow and transitions",
      "Fix grammar only",
      "Translate to English",
    },
    -- width of the chat split: columns, or a fraction of 'columns'
    chat_width = 0.4,
  },
  spell = {
    suggestions = 9,
  },
  -- The style guide sent with every request (and checked by :Writing conform):
  -- a path, or a list of paths in order of preference, searched upward from
  -- the file (the nearest directory wins); function(buf) -> text?, path?; or
  -- false for none. .nvim/writing.md is the old location, still read.
  style_guide = { "STYLE.md", ".nvim/writing.md" },
  -- function(prompt, ctx) that starts the companion chat in ctx.win (a fresh
  -- vertical split); ctx = { buf, file, win }. nil = `:terminal claude <prompt>`.
  chat = nil,
  -- Highlight overrides, { SpellAuditSel = { bg = … }, … }, or a function
  -- returning them; re-applied on every ColorScheme.
  highlights = {},
}

M.options = vim.deepcopy(M.defaults)

-- The tasks that call Claude, each with its own model and effort.
M.TASKS = { "grammar", "conform", "restyle", "rigor", "outline", "assist", "talk" }

-- `:Writing model` overrides, per task ({ model?, effort? }). Kept until
-- Neovim exits; setup() doesn't reset them.
M.session = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- lists replace, they don't merge by index
  local presets = vim.tbl_get(opts or {}, "assist", "presets")
  if presets then M.options.assist.presets = presets end
  if type(vim.tbl_get(opts or {}, "style_guide")) == "table" then M.options.style_guide = opts.style_guide end
end

--- A task's options for one run: setup() options < session overrides <
--- `o.model` / `o.effort` (a per-run `:Writing … model=… effort=…`).
function M.task(name, o)
  o = o or {}
  return vim.tbl_extend("force", M.options[name], M.session[name] or {},
    { model = o.model, effort = o.effort })
end

return M
