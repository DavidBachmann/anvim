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

The cursor moves between the code window and the prompt in one step: `Ctrl-W l` or `Ctrl-L` from any row of the code window, and `Ctrl-W h` or `Ctrl-H` back. Entering the prompt starts insert mode where you stopped typing. The transcript takes no focus. A window key that would land on it skips it, a click on it goes to the prompt, and the mouse wheel scrolls it from anywhere. New output keeps the transcript at its end, unless you scrolled up. Then it stays put until you scroll back down or send a prompt. To yank or search the transcript, enter read mode with `<leader>kr`, or drag across it with the mouse.

Only one window shows files, so anvim always knows which file you are looking at. A split, a picker's split action or `:diffsplit` opens the file in the code window instead. Help, quickfix, terminal and plugin windows open as usual. If you close the code window, the transcript or the prompt, anvim opens it again. `:q` in any of them quits anvim, also when other tabs are open.

Claude can also use your editor. It points at code with `show_user`, which marks a range and puts a short note above it until your next prompt. It asks the language servers that run in anvim for diagnostics, definitions, references, hover text and symbols, so it greps less. These tools work in every permission mode, so they read only files inside the directory that anvim opened. `show_user` can point at any file, because its answer holds no file text.

All of LazyVim's keys and your own work as usual. anvim adds these. `<leader>` is Space.

| Key | Where | Action |
| --- | --- | --- |
| `Enter` | prompt | Send |
| `Shift-Enter`, `Alt-Enter` | prompt, insert mode | New line |
| `Esc` (normal mode), `Ctrl-C` | prompt | Interrupt Claude |
| `Shift-Tab` | prompt | Cycle the permission mode |
| `PageUp`, `PageDown` | prompt | Scroll the transcript |
| `Ctrl-U`, `Ctrl-D`, `Ctrl-B`, `Ctrl-F` | prompt, normal mode | Scroll the transcript |
| `i`, `a` | file buffer | Go to the prompt |
| `Ctrl-W l`, `Ctrl-L` | explorer | Go to the code window |
| `<leader>j`, `<leader>kj` | anywhere | Jump to where Claude is |
| `<leader>kr`, `:AnvimTranscript` | anywhere | Read the transcript: put the cursor in it to yank and search |
| `q`, `Esc`, `i` | transcript in read mode | Go back to the prompt |

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
