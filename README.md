# quill.nvim

A proofreading kit for Neovim: a **spell audit** that walks every spelling issue in a float, and **Claude** (a cheap model through the `claude` CLI and your Claude Code login) as copy editor, peer reviewer, developmental editor and reader. It works on Markdown, LaTeX, Typst and plain text.

```
 This sentense has a mistaek in it.
  ╭─ Spell 1/2 ──────────────────────────────────────────────────────────────╮
  │ This sentense has a mistaek in it.                                       │
  │ misspelled                                                               │
  │                                                                          │
  │ 1  sentence                                                              │
  │ 2  sentences                                                             │
  ╰─ 1-9 fix · R all · e edit · s skip · S ignore · a add · u undo · q quit ─╯
```

- **Spell audit** (`:SpellAudit`, offline): every issue `]s` would visit, one at a time. Replace, replace all, ignore, add to the spellfile, skip, and an exact `u`.
- **Grammar audit** (`:Writing grammar` / `style`): issues come back as verbatim quotes, so hallucinated ones are dropped. They're anchored as extmarks that move with your edits, mirrored as diagnostics, and walked in the same float.
- **Rigor review** (`:Writing rigor`): a peer review of research writing. It flags unsupported or overclaimed statements, fallacies, cross-section inconsistencies, misused statistics and method gaps. You get a report panel plus a walk, where `m` drops a `TODO(review)` comment.
- **Reverse outline** (`:Writing outline`): summary, role and flags per paragraph, plus the thesis as the text actually argues it.
- **Rewrite / ask / chat** on the selection or the paragraph under the cursor.

Nothing runs on its own. Text only leaves Neovim when you start a pass, and results are cached, so a repeated pass only sends what changed.

## Requirements

- Neovim ≥ 0.10
- For the Claude features: [Claude Code](https://claude.com/claude-code) (`claude`), logged in. No API key is needed; requests count against your plan.

Run `:checkhealth writing` to check. Set `vim.g.writing_health_request = true` to also send a one-word test request.

> `--bare` can't be used (in `claude.args` or anywhere else): it skips keychain reads, so it can't authenticate with your Claude Code login.

## Install

lazy.nvim:

```lua
{
  "Lunaaaalj/quill.nvim",
  cmd = { "Writing", "SpellAudit" },
  keys = {
    { "<leader>sa", "<Plug>(SpellAudit)", remap = true, desc = "Spell audit" },
    { "<leader>Wg", "<Plug>(WritingGrammar)", remap = true, desc = "Grammar audit" },
    { "<leader>WG", "<Plug>(WritingStyle)", remap = true, desc = "Grammar + style audit" },
    { "<leader>Wp", "<Plug>(WritingParagraph)", remap = true, desc = "Grammar audit: paragraph" },
    { "<leader>Wa", "<Plug>(WritingRigor)", remap = true, desc = "Rigor review" },
    { "<leader>Wo", "<Plug>(WritingOutline)", remap = true, desc = "Reverse outline" },
    { "<leader>Wr", "<Plug>(WritingRewrite)", remap = true, mode = { "n", "x" }, desc = "Rewrite" },
    { "<leader>Wq", "<Plug>(WritingAsk)", remap = true, mode = { "n", "x" }, desc = "Ask" },
    { "<leader>Wc", "<Plug>(WritingChat)", remap = true, desc = "Companion chat" },
  },
  opts = {},
}
```

`remap = true` matters: a non-recursive map to a `<Plug>` does nothing (lazy.nvim and `vim.keymap.set` both default to noremap).

The module is `writing` (`require("writing").setup(opts)`); `setup()` is optional.

## Usage

| Command | |
| --- | --- |
| `:SpellAudit` | walk every spelling issue (run again to resume) |
| `:Writing [grammar]` / `style` / `paragraph` | grammar audit (+ style hints) of the buffer / paragraph |
| `:Writing rigor` | rigor review: report panel + walk |
| `:Writing outline` | reverse outline panel |
| `:[range]Writing rewrite` / `ask` | on the paragraph, the lines, or the visual selection |
| `:Writing chat` | companion chat in a split |
| `:Writing diagnostics` / `clear` | toggle / clear the AI diagnostics |

Walker keys: `1`–`9` / `<CR>` fix, `e` edit, `s` skip, `u` undo, `q` pause. Spell adds `R` replace all, `S` ignore, `a` add to spellfile. Grammar and rigor add `d` dismiss for good. Rigor adds `m` TODO comment.

Every map is a `<Plug>` (see `:help quill-mappings`).

## Style guide

A `.nvim/writing.md` in any directory above the file is sent with every request: audience, register, conventions, terms to leave alone. Words in your `'spellfile'` are never "corrected". The language comes from `'spelllang'`.

## Configuration

```lua
require("writing").setup({
  claude = { command = "claude", args = {}, timeout = 180000, max_jobs = 3 },
  grammar = { model = "haiku", effort = "low", chunk_chars = 6000 },
  outline = { model = "haiku", effort = "high", width = 60 },
  rigor   = { model = "haiku", effort = "high", width = 64 },
  assist  = { model = "haiku", effort = "medium", presets = { … }, chat_width = 0.4 },
  spell   = { suggestions = 9 },
  style_guide = ".nvim/writing.md", -- or function(buf) -> text, path; or false
  chat = nil,        -- function(prompt, ctx): open the chat in ctx.win
  highlights = {},   -- or a function, re-run on every ColorScheme
})
```

The highlight groups (`SpellAudit*`, `Writing*`) are `default` links. The filetypes are `spellaudit` (walker float), `writingoutline` (outline/rigor panels) and `writingassist`. The full reference is in `:help quill`.

## Tests

```
make test
```

Headless, with no dependencies. `claude.run` is stubbed, and the XDG dirs point at a temp dir.
