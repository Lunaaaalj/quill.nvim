# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

quill.nvim is a Neovim (≥ 0.10) proofreading plugin written in pure Lua (LuaJIT). It has an offline spell audit and Claude-powered passes (grammar/style audit, STYLE.md conformance and paragraph restyle, rigor review, reverse outline, rewrite/ask, chat). The passes run through the `claude` CLI and the user's Claude Code login. There is no API key. **The repo is named quill, but the Lua module is `writing`** (`require("writing")`, `lua/writing/`, `:checkhealth writing`, help tag `quill`).

## Commands

- `make test` runs the whole suite headless (`nvim --headless --clean -c "luafile tests/run.lua"`) with throwaway XDG dirs. The exit code is non-zero on failure. There are no dependencies.
- There is no per-test filter. To focus on one test, temporarily comment out the others in `tests/run.lua`, or run the `nvim --headless --clean -c "luafile tests/run.lua"` line from the Makefile directly.
- There is no linter or formatter config beyond `.luarc.json` (LuaJIT runtime, `vim` global) for lua-language-server.

## Tests

`tests/run.lua` is one file with a tiny `test(name, fn)` / `eq(got, expected)` harness. Each test starts with `%bwipeout!`. Things to know when adding tests:
- `claude.run` is replaced by a stub that answers from the mutable `reply(o)` function and counts calls in `calls`. Set `reply` to return the JSON a pass expects. Nothing ever shells out to `claude`.
- `keys(k)` feeds keys with mode `"x"`, so walker mappings run synchronously.
- `buf_with(lines, ft)` makes a scratch buffer. `vim.notify` is silenced.
- Tests that call `require("writing.config").setup({...})` must reset it with `setup({})` afterwards.

## Architecture

**Entry points.** `plugin/quill.lua` defines `:Writing {sub}`, `:SpellAudit` and every `<Plug>(…)` map. It binds no keys and does nothing else at startup. Everything goes through `require("writing")` (`init.lua`), whose actions call `M.ensure()`, which lazily runs `setup()` (autocmds for issues/outline/rigor) on first use. `setup()` is optional and safe to call more than once.

**Config and models.** `config.lua` deep-merges opts over `M.defaults`. Lists replace rather than merge (`assist.presets`, `style_guide`). A pass that calls Claude resolves its options **once per run** with `config.task(name, o)`. That merges `setup()` options, then `config.session[name]` (from the `:Writing model` picker; `setup()` does not reset it), then `o.model`/`o.effort` (from `:Writing <sub> model=… effort=…`). The result `c` is threaded through the run, including into cache keys. Don't read `options.<task>.model` directly. Non-model options (widths) may still be read at call time.

**Claude transport (`claude.lua`).** `M.run({prompt, system, schema?, model?, effort?}, cb)` runs `claude -p --output-format json --tools "" --no-session-persistence --system-prompt …`, sending the prompt on stdin. With `schema`, it passes `--json-schema` and returns `structured_output`. Jobs are queued and capped at `claude.max_jobs`. Requests run in an empty cwd under `stdpath("cache")/writing/cwd` so that no CLAUDE.md gets read into them. **Never use `--bare`**: it skips keychain reads and breaks login auth.

**Pipeline shared by the AI passes:**
1. `prose.lua` splits the buffer into paragraphs (runs of non-blank lines). It skips non-prose by filetype: Markdown front matter, fences and comments; the LaTeX preamble, math and verbatim envs; Typst `#set`/`#show`/raw/math. It also loads the language (`'spelllang'`), the glossary (`'spellfile'` words) and the style guide. `prose.profile` searches upward for `STYLE.md`, falling back to the legacy `.nvim/writing.md`; the nearest directory wins, and within one directory the list order decides. `prose.locate` finds a quote in a paragraph with whitespace collapsed.
2. Claude answers with **verbatim quotes** plus replacements and notes.
3. `issues.lua` stores anchor each quote as an extmark. A quote that isn't found (a hallucination) or that overlaps an earlier one is dropped. `items()` returns only the extmarks whose current text still equals the quote, so fixed issues disappear and `u` brings them back. Each store mirrors its items as `vim.diagnostic` in its own namespace and persists dismissals (`d`) as JSON in `stdpath("state")/writing`. `f.key` is computed **once at anchor time**, and dismissals and "later" use it, because talk replaces `f.suggestions` and `dismiss_key` hashes `suggestions[1]`. `I.check_needs` runs in `anchor`: a suggestion that brings in a number, citation key or placeholder not in the buffer (`facts.lua`) is withheld, and the finding is kept with `f.needs`. Such findings bypass `need_fix`, show as WARN diagnostics with code `needs-input`, and are counted by `I.counts`. Talk re-checks its new suggestion against the buffer plus the author's messages; when it passes, `needs` is cleared. The file also holds the persistent "later" set (`I.later`/`I.set_later`) and `Store:talk_action()` (the `t` key: a one-shot `claude.run` with the conversation so far in `f.talk`; it puts the new suggestion first).
4. `walker.lua` is the single audit float used by spell, grammar, conform, restyle and rigor. A *source* table supplies `title`, `key`, `buf`/`win`, `issues(S)` (rescanned after every action), optional `suggestions`, `later_key(S, it)` (enables `l`; stores pass `store.later_key`), `diff` (render suggestion 1 as a word diff, `W.word_diff`), extra `keys`, `footer`, `empty`, and `on_finish`. The walker owns the float, highlights, skip, later, undo and resume. `W.step` walks fresh issues first and deferred ones (`it.deferred`) only after them, and `W.replace` forgets a deferred issue once it's fixed. `W.place` positions the float against the issue's whole screen extent (below its last line, else above its first, scrolling if needed), so it never hides the text being compared, which matters for multi-line restyle paragraphs. New walk-style features should be built as a walker source.

**Passes.**
- `spell.lua` (offline): finds issues with `]s` + `spellbadword()`, not by string matching, so it visits exactly what `]s` would (and respects `@nospell`).
- `grammar.lua`: batches paragraphs into requests of up to `grammar.chunk_chars`. Results are cached per paragraph, keyed on text, model, mode, language and style guide, so a re-run only sends changed paragraphs.
- `conform.lua`: grammar-shaped (per-paragraph cache keyed on the guide's hash, batches). It errors when there is no guide. Each finding must cite a `rule` that `M.verified` finds verbatim in the guide; otherwise it is dropped, the same way unmatched quotes are.
- `restyle.lua`: paragraph rewrites, one finding per paragraph (`quote` = the whole paragraph), walked with `diff = true`. `M.finding` drops a rewrite when a change's rule isn't in the guide or when `facts.lost` reports dropped markup. Unchanged paragraphs are cached as `answer = nil`.
- `facts.lua`: pure checks, `facts`/`invented` (numbers, including number words except "one"; citation keys; placeholders) and `lost` (markup). Every check against made-up content goes through it, including the warning line in the rewrite float.
- `rigor.lua`: whole-document review. It produces a report panel plus a walk. `m` (`Store:todo_action`, shared with conform and restyle) inserts a `TODO(<tag>)` comment in the file's comment syntax.
- `outline.lua`: a panel to the right with a role and flags per paragraph. Its flags are also diagnostics.
- `assist.lua`: rewrite and ask on the selection or the paragraph, shown in floats (accepting is one undo step), and chat in a split (the `chat` hook, else `:terminal claude`).

**Highlights and filetypes.** `hl.lua` defines every group as a `default` link (`SpellAudit*`, `Writing*`), so colorschemes win. It is re-applied on `ColorScheme`. Plugin UI filetypes are `spellaudit`, `writingoutline` and `writingassist`.

**Docs.** User-facing behavior is documented in both `README.md` and `doc/quill.txt` (`:help quill`). Update both when commands, keys or options change. Resume hints come from `require("writing").hint(plug, fallback)`, which shows the user's own mapped key.
