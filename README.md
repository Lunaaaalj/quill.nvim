# quill.nvim

A proofreading kit for Neovim: a **spell audit** that walks every spelling issue in a float, and **Claude** (through the `claude` CLI and your Claude Code login) as copy editor, house-style checker, peer reviewer, developmental editor and reader. It works on Markdown, LaTeX, Typst and plain text.

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
- **Style check** (`:Writing conform`): your `STYLE.md` used as a rulebook. Each finding cites the rule it breaks, word for word, and comes with a rewrite you accept, reject, skip, leave for later, or **talk about** (`t`). Talking gets you a reply and a new suggestion. A finding that cites a rule not in your guide is dropped.
- **Rigor review** (`:Writing rigor`): a peer review of research writing. It flags unsupported or overclaimed statements, fallacies, cross-section inconsistencies, misused statistics and method gaps. You get a report panel plus a walk, where `m` drops a `TODO(review)` comment.
- **Reverse outline** (`:Writing outline`): summary, role and flags per paragraph, plus the thesis as the text actually argues it.
- **Rewrite / ask / chat** on the selection or the paragraph under the cursor.

In every walk, `l` **leaves an issue for later**. It's saved across sessions and comes back after the fresh issues next time; `:Writing later` lists them all.

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
    { "<leader>Ws", "<Plug>(WritingConform)", remap = true, desc = "Check against STYLE.md" },
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
| `:Writing conform` | check against your STYLE.md: walk the findings |
| `:Writing rigor` | rigor review: report panel + walk |
| `:Writing outline` | reverse outline panel |
| `:[range]Writing rewrite` / `ask` | on the paragraph, the lines, or the visual selection |
| `:Writing chat` | companion chat in a split |
| `:Writing later` | what you left for later, in the quickfix list |
| `:Writing model [reset]` | pick a task's model and effort for this session |
| `:Writing diagnostics` / `clear` | toggle / clear the AI diagnostics |

Every Claude subcommand takes `model=` and `effort=` for one run: `:Writing rigor model=opus effort=high`.

Walker keys: `1`–`9` / `<CR>` fix, `e` edit, `s` skip, `l` later, `u` undo, `q` pause. Spell adds `R` replace all, `S` ignore, `a` add to spellfile. Grammar, conform and rigor add `d` dismiss for good and `t` talk. Rigor adds `m` TODO comment.

Every map is a `<Plug>` (see `:help quill-mappings`).

## Style guide

Put a `STYLE.md` at the project root and commit it, so every collaborator works from the same rules. The nearest one above the file is sent with every request (audience, register, conventions, terms to leave alone), and `:Writing conform` checks the text against it. Write rules you could check a sentence against:

```markdown
- Use the active voice.
- Write numbers under ten as words.
- Say "participants", never "subjects".
```

The old location, `.nvim/writing.md`, is still read when there's no `STYLE.md`. Words in your `'spellfile'` are never "corrected". The language comes from `'spelllang'`.

## Models

Each task (`grammar`, `conform`, `rigor`, `outline`, `assist`, `talk`) has its own model and effort. Grammar, outline, rigor and assist default to `haiku`; conform and talk default to `sonnet`, because following a rulebook takes more. A run uses the first of these that is set: a `model=`/`effort=` argument on the command, then `:Writing model` (for the session), then `setup()`. Requests count against your own plan, so models are a personal setting rather than a project file. `:checkhealth writing` shows what each task uses.

## Configuration

```lua
require("writing").setup({
  claude = { command = "claude", args = {}, timeout = 180000, max_jobs = 3 },
  grammar = { model = "haiku", effort = "low", chunk_chars = 6000 },
  conform = { model = "sonnet", effort = "medium", chunk_chars = 6000 },
  talk    = { model = "sonnet", effort = "low" },
  outline = { model = "haiku", effort = "high", width = 60 },
  rigor   = { model = "haiku", effort = "high", width = 64 },
  assist  = { model = "haiku", effort = "medium", presets = { … }, chat_width = 0.4 },
  spell   = { suggestions = 9 },
  style_guide = { "STYLE.md", ".nvim/writing.md" }, -- or a path, function(buf) -> text, path, or false
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
