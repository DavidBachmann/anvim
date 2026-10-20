# anvim

A read-only Neovim for watching Claude Code work. You read and point; Claude writes, and its edits stream into your buffers as they are generated. This is a personal tool and is not distributed.

## Requirements

- Neovim 0.12 or newer
- [Bun](https://bun.sh)
- Claude Code, logged in (`claude /login`)
- Google Chrome, only for the screen tool

## Install

From the repo root:

```sh
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

The first launch installs the Neovim plugins with `vim.pack` and the sidecar's packages with Bun.

## Use

```sh
anvim [--model <model>] [dir] [nvim args...]
anvim --model haiku ~/dev/project
```

The screen has three columns: tree, code, and Claude. Type in the prompt at the bottom right. While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Move the cursor anywhere else to take control. The statusline then shows where Claude is.

File buffers are read-only. Claude makes every change, and buffers reload when files change on disk.

`<leader>` is Space.

| Key | Where | Action |
| --- | --- | --- |
| `Enter` | prompt | Send |
| `Shift-Enter`, `Alt-Enter` | prompt, insert mode | New line |
| `Esc` (normal mode), `Ctrl-C` | prompt | Interrupt Claude |
| `Shift-Tab` | prompt | Cycle the permission mode |
| `i`, `a` | file buffer | Go to the prompt |
| `<leader>j` | anywhere | Jump to where Claude is |
| `<leader><space>` | anywhere | Find files |
| `<leader>/` | anywhere | Grep |
| `<leader>e` | anywhere | Toggle the tree |

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
~/.local/share/nvim/mason/bin/stylua --check . && selene .
```

`scripts/test` runs the Neovim specs in `tests/`. Its first run downloads the test plugins into `.tests/`, and later runs work offline. Run `:checkhealth anvim` when something does not start.

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. See the header of that file for its steps. The log is at `~/.local/state/anvim/anvim.log`.
