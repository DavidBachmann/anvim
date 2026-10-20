# anvim

A read-only Neovim for watching Claude Code work. You read and point; Claude writes, and its edits stream into your buffers as they are generated. This is a personal tool and is not distributed.

## Requirements

- Neovim 0.12 or newer
- [LazyVim](https://www.lazyvim.org), with its config at `~/.config/nvim` and its plugins installed in `~/.local/share/nvim/lazy`
- [Bun](https://bun.sh)
- Claude Code, logged in (`claude /login`)
- Google Chrome, only for the screen tool

## Install

From the repo root:

```sh
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

anvim installs no Neovim plugins. It boots your LazyVim setup with your extras, plugins, keys, LSP servers and colorscheme, and adds anvim on top. Treesitter parsers and mason tools come from your main Neovim too, so install and update them there. anvim keeps its own state, undo history and logs in `~/.local/state/anvim`. At startup it never writes your plugins, your lockfile or `lazyvim.json`. `:Lazy update` inside anvim does update the shared plugins and lockfile, as it does in your main Neovim. The first launch installs the sidecar's packages with Bun.

## Use

```sh
anvim [--model <model>] [dir] [nvim args...]
anvim --model haiku ~/dev/project
```

The screen has three columns: your explorer, code, and Claude. Type in the prompt at the bottom right. While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Move the cursor anywhere else to take control. The statusline then shows where Claude is.

File buffers are read-only. `:w` does nothing but say so, and format on save never runs. Claude makes every change, and buffers reload when files change on disk.

Claude can also use your editor. It points at code with `show_user`, which marks a range and puts a short note above it until your next prompt. It asks the language servers that run in anvim for diagnostics, definitions, references, hover text and symbols, so it greps less. These tools work in every permission mode, so they read only files inside the directory that anvim opened. `show_user` can point at any file, because its answer holds no file text.

All of LazyVim's keys and your own work as usual. anvim adds these. `<leader>` is Space.

| Key | Where | Action |
| --- | --- | --- |
| `Enter` | prompt | Send |
| `Shift-Enter`, `Alt-Enter` | prompt, insert mode | New line |
| `Esc` (normal mode), `Ctrl-C` | prompt | Interrupt Claude |
| `Shift-Tab` | prompt | Cycle the permission mode |
| `i`, `a` | file buffer | Go to the prompt |
| `<leader>j` | anywhere | Jump to where Claude is |

anvim starts in bypass permissions mode. Permission prompts are not built yet, so in the other modes Claude cannot run tools that need approval.

## Record and replay

```sh
ANVIM_RECORD=session.jsonl anvim --model haiku   # save every event
ANVIM_REPLAY=session.jsonl anvim                 # play it back, with no API cost
```

Each prompt you send during a replay plays the next recorded turn.

## Development

```sh
cd sidecar && bunx tsc --noEmit && bun test
scripts/test
scripts/test-stack
~/.local/share/nvim/mason/bin/stylua --check . && selene .
```

`scripts/test` runs the Neovim specs in `tests/`. Its first run downloads the test plugins into `.tests/`, and later runs work offline. `scripts/test-stack` boots the real `init.lua` with your LazyVim config in a child Neovim, with temporary state dirs, and checks that your main Neovim stays unchanged. Run `:checkhealth anvim` when something does not start.

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. See the header of that file for its steps. The log is at `~/.local/state/anvim/anvim.log`.
