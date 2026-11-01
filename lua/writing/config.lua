-- Defaults, merged with setup() opts into M.options. Every module reads
-- M.options at call time, so changing an option takes effect on the next run.

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
  -- The style guide sent with every request: a path searched upward from the
  -- file (string), function(buf) -> text?, path?, or false for none.
  style_guide = ".nvim/writing.md",
  -- function(prompt, ctx) that starts the companion chat in ctx.win (a fresh
  -- vertical split); ctx = { buf, file, win }. nil = `:terminal claude <prompt>`.
  chat = nil,
  -- Highlight overrides, { SpellAuditSel = { bg = … }, … }, or a function
  -- returning them; re-applied on every ColorScheme.
  highlights = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- lists replace, they don't merge by index
  local presets = vim.tbl_get(opts or {}, "assist", "presets")
  if presets then M.options.assist.presets = presets end
end

return M
