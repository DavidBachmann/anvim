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
anvim [--model <model>] [--mode <mode>] [dir] [nvim args...]
anvim --model haiku ~/dev/project
anvim --mode default ~/dev/project              # approve tools as Claude asks
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

## Permissions

anvim starts in bypass permissions mode, so Claude runs every tool without asking. Start it with `--mode default` to approve tools as Claude asks for them, or with `--mode acceptEdits` or `--mode plan`. `Shift-Tab` in the prompt cycles default, accept edits and plan mode, plus bypass when anvim started in it.

When Claude needs your yes, the request appears at the bottom of the Claude column, as in Claude Code. An edit streams into the code window before the request opens, so you see the change before you answer. If you say no, the buffer shows the file on disk again. Claude's questions and its plan, when it wants to leave plan mode, appear the same way. If your cursor is outside the prompt, anvim leaves it there, posts a notification and shows "⏺ Claude is waiting" in the statusline. A request brings the transcript to its end, even if you scrolled it up. In read mode the transcript stays where you read, and it goes to the request when you leave read mode. `Esc` there takes you back to the prompt and answers nothing. A choice key never answers a request that is out of view: it brings the request into view instead.

| Key | In the prompt in normal mode, while Claude waits |
| --- | --- |
| `1` to `9` | Choose that option |
| `j`, `k`, then `Enter` | Move to an option and choose it |
| `Esc` | No |

While a request waits, normal mode in the prompt is for choosing. Typing your prompt never answers: if you are typing when a request opens, you keep typing, digits are text, and `Enter` keeps your prompt without sending it or answering. Press `Esc`, then choose. `Enter` chooses only after `j` or `k`, so `Esc` and `Enter`, the habit of sending a prompt, does nothing. A choice also does nothing within 0.4 s of the request opening or of the last character you typed. Going to the prompt while Claude waits leaves you in normal mode. After you answer, the prompt goes back to insert mode where you stopped typing, if you were typing.

"No, and tell Claude what to do differently", "No, keep planning" and a question's "Other" take typed text. `Enter` sends it, and `Esc` twice goes back to the options. Your draft prompt comes back afterwards. If Claude Code names a path outside the working directory, the request shows it. "Yes, and don't ask again" names the rules that Claude Code suggests, such as `Bash(npm test:*)`, and applies them all. Claude Code saves project rules in the project's `.claude/settings.local.json`. Plan approval offers Claude Code's choices: accept edits or manual approval, with bypass in place of accept edits when anvim started in bypass mode. The plan stays in the transcript. A multi-select question has a Submit option after its choices.

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
scripts/test-ui
~/.local/share/nvim/mason/bin/stylua --check . && selene .
cd tools/screen && bunx tsc --noEmit
```

`scripts/test` runs the Neovim specs in `tests/`. Its first run downloads the test plugins into `.tests/`, and later runs work offline. `scripts/test-stack` boots the real `init.lua` with your LazyVim config in a child Neovim, with temporary state dirs, and checks that your main Neovim stays unchanged. `scripts/test-ui` embeds anvim with a UI attached and checks the frames it draws: splits that fold back, the cursor after a close, mouse drags, resizes, and permission prompts typed at a user's pace. Run `:checkhealth anvim` when something does not start.

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. See the header of that file for its steps. It shares its UI client, `tools/screen/ui.ts`, with the UI tests. The log is at `~/.local/state/anvim/anvim.log`. A screen tool run keeps its own in a temp dir, and prints its path.
