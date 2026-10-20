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
anvim [--model <model>] [--mode <mode>] [-c | --continue | -r | --resume [id]] [dir] [nvim args...]
anvim --model haiku ~/dev/project
anvim --mode default ~/dev/project              # approve tools as Claude asks
anvim -c ~/dev/project                          # go on with the latest session there
anvim --resume ~/dev/project                    # pick a session to go on with
```

The screen has three columns: your explorer, code, and Claude. The explorer is 24 columns wide. While it has focus, it widens over the code window to fit its names, and the code window stays where it is. anvim starts with the cursor in the prompt at the bottom right, in normal mode, so your first keys can move around. Press `i` to type. While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Move the cursor anywhere else to take control. The statusline then shows where Claude is.

File buffers are read-only. `:w` does nothing but say so, and format on save never runs. Claude makes every change, and buffers reload when files change on disk. Markdown and text files wrap, with no spell checking.

The cursor moves between the code window and the prompt in one step: `Ctrl-W l` or `Ctrl-L` from any row of the code window, and `Ctrl-W h` or `Ctrl-H` back. Moving into the prompt leaves you in normal mode. Only insert commands start typing: `i`, `a` and the others in the prompt. In a file buffer, `i`, `a`, `I`, `A`, `o` and `O` go to the prompt and type where you stopped. The transcript takes no focus. A window key that would land on it skips it, a click on it goes to the prompt, and the mouse wheel scrolls it from anywhere. New output keeps the transcript at its end, unless you scrolled up. Then it stays put until you scroll back down or send a prompt. To yank or search the transcript, enter read mode with `<leader>kr`, or drag across it with the mouse.

For a long prompt, `Ctrl-G` in the prompt opens it in a large window in the middle of the screen, as Claude Code's `Ctrl-G` opens it in your editor. There `Enter` adds a line, and `@` and `/` complete as in the prompt. `Ctrl-G` again, `:wq` or `ZZ` puts the text back in the prompt, at the same place and in the same mode: after `Ctrl-G` while typing you go on typing, and after `:wq` you are in normal mode. `:w` puts it there and keeps the window open, and `:q!` drops your changes. Leaving the window keeps the text too. Follow mode goes on while you write.

Only one window shows files, so anvim always knows which file you are looking at. A split, a picker's split action or `:diffsplit` opens the file in the code window instead. Help, quickfix, terminal and plugin windows open as usual. If you close the code window, the transcript or the prompt, anvim opens it again. `:q` in any of them quits anvim, also when other tabs are open.

Claude can also use your editor. It points at code with `show_user`, which marks a range and puts a short note above it until your next prompt. It asks the language servers that run in anvim for diagnostics, definitions, references, hover text and symbols, so it greps less. These tools work in every permission mode, so they read only files inside the directory that anvim opened. `show_user` can point at any file, because its answer holds no file text.

All of LazyVim's keys and your own work as usual. anvim adds these. `<leader>` is Space.

| Key | Where | Action |
| --- | --- | --- |
| `Enter` | prompt | Send |
| `Shift-Enter`, `Alt-Enter` | prompt, insert mode | New line |
| `Up` on the first line, `Down` on the last | prompt, insert mode | Go back and forth through past prompts |
| `Ctrl-P`, `Ctrl-N` | prompt, normal mode | Go back and forth through past prompts |
| `Esc` (normal mode), `Ctrl-C` | prompt | Interrupt Claude |
| `Shift-Tab` | prompt | Cycle the permission mode |
| `PageUp`, `PageDown` | prompt | Scroll the transcript |
| `Ctrl-U`, `Ctrl-D`, `Ctrl-B`, `Ctrl-F` | prompt, normal mode | Scroll the transcript |
| `Ctrl-X` | prompt | Unpin the selection |
| `Ctrl-G` | prompt | Write the prompt in a large window. `Ctrl-G` there goes back |
| `@`, `/` | prompt, insert mode | Complete a file, or a slash command at the start |
| `i`, `a`, `I`, `A`, `o`, `O` | file buffer | Go to the prompt and type where you stopped |
| `c` | file buffer, visual mode | Put a reference to the selected lines in the prompt |
| `c{motion}`, `cc` | file buffer | Put a reference to the lines of the motion in the prompt |
| `Ctrl-L` | file buffer, visual mode | Go to the prompt and keep the selection |
| `Ctrl-W l`, `Ctrl-L` | explorer | Go to the code window |
| `@` | explorer | Put a reference to the file in the prompt |
| `<leader>j`, `<leader>kj` | anywhere | Jump to where Claude is |
| `<leader>kt`, `:AnvimTrail` | anywhere | Pick a place from Claude's trail |
| `<leader>kr`, `:AnvimTranscript` | anywhere | Read the transcript: put the cursor in it to yank and search |
| `<leader>ky` | anywhere | Yank Claude's last reply to the clipboard |
| `<leader>ks`, `:AnvimSessions` | anywhere | Resume a session of this directory |
| `<leader>km`, `:AnvimModel` | anywhere | Choose Claude's model |
| `:AnvimRestart` | anywhere | Start Claude again, in the same session |
| `q`, `Esc` | transcript in read mode | Go back to the prompt |
| `i`, `a`, `I`, `A`, `o`, `O` | transcript in read mode | Go back to the prompt and type |

## Sessions

Claude Code saves every session, and anvim reads them through the Agent SDK. `anvim -c` goes on with the latest session in the directory, and `anvim --resume <id>` with that one. `--resume` without an id opens the session picker at start. In anvim, `<leader>ks` or `/resume` opens it: each session shows its title or first prompt, when it changed, its size and its branch, with details in the preview. Choosing one starts Claude again in that session and draws its past in the transcript, as it looked live. A session that Claude Code compacted starts at the compaction, because Claude Code keeps only the summary. Saved sessions do not keep what went with each prompt, so a resumed transcript shows no `⎿  ⧉` lines.

`/clear` starts a new session and empties the transcript. `<leader>km` or `/model` lists the models that Claude Code offers, and the footer shows the one you choose. `/model sonnet` switches at once. `:AnvimRestart` starts Claude again when it exited or hangs, in the same session, and keeps the model you chose. Other slash commands run in Claude Code, and their output shows under them, such as the text of `/cost`. As in Claude Code, `Enter` on a slash command in the completion menu completes it and sends it. A command that needs an argument, such as `/batch <instruction>`, is only completed, so you can type the argument.

Your prompts are saved per directory, the last 200, in anvim's state dir. `Up` on the first line of the prompt goes back through them, and `Down` on the last line comes forward again, back to what you were typing. While the completion menu is open, `Up` and `Down` move in the menu instead.

When Claude is done, or needs your answer, while the terminal does not have focus, anvim posts a desktop notification. Inside cmux, it uses `cmux notify` for its own pane. Elsewhere it writes OSC 9, which many terminals show as a notification. It never notifies while you look at it.

## The transcript

Claude's replies render their markdown, as in Claude Code: bold, inline code and links show without their markers, and code blocks have syntax colors. Tool lines, their results and your prompts show as they are, so a command such as `grep '**' *.lua` keeps its stars. Paths under the working directory show short: `Bash(find . -name '*.lua')`.

Claude's todo list stays at the end of the transcript, under the newest output, while it has open items. Claude Code keeps it with TodoWrite, or with TaskCreate and TaskUpdate. For its newest models, it offers these tools only when `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set. The item in progress is bold, and the spinner names it. Once every item is done, the list stays in the transcript where it was. A subagent shows its last three tool calls under its line while it works, and then a summary such as `Done (12 tool uses · 24.1k tokens · 1m 2s)`. A compaction shows as a notice with the tokens before and after. When Claude is idle, the line above the prompt shows the last turn's time and cost, and how full the context window is.

## Pointing

Claude always knows what you look at. Each prompt tells it the file in the code window, the cursor line and the visible lines, so "What does this file do?" needs no reference. The footer under the prompt shows what the next prompt carries: `⧉ In stream.lua`.

Select lines in the code window, in any visual mode, and go to the prompt: `Ctrl-L`, `Ctrl-W l`, a click, or `Esc` and then `i`. The selection stays highlighted, and the footer says `⧉ 19 lines selected`. Your next prompt carries it, and sending that prompt unpins it. It also goes when you move on: move the cursor in the code window, open another file, start a new selection, or press `Esc` in normal mode there. Scrolling keeps it. `Ctrl-X` in the prompt unpins it. When Claude edits the file, the selection goes, because its text changed. A long selection gives Claude its line numbers and its first 2000 characters, as Claude Code's IDE integrations do. Slash commands run in Claude Code and carry no editor context.

While a selection is pinned, follow mode waits, so the code window keeps what you point at. The statusline says so, for example `⏸ pinned · Claude at stream.lua:40 +2`. Once the prompt is sent or the pin goes, the code window catches up with Claude, also with a file that Claude is still writing. `<leader>j` unpins and goes to Claude at once.

References are text in the prompt, in the form `@path#L12-30`, and you can write several. In a file buffer, `c` puts one in the prompt and goes on typing after it: `c` in visual mode for the selection, `c{motion}` for the lines of a motion such as `cip` or `cj`, and `cc` for the current line or, with a count, more lines. Read-only buffers leave `c` free, so read it as "change this, Claude". `@` in the explorer references whole files and leaves the cursor after them, in normal mode. In the prompt, `@` completes files and directories, and `/` at the start completes slash commands. The transcript shows what went with each prompt, dimmed under it: `⎿  ⧉ stream.lua#L12-30`.

`<leader>kt` opens Claude's trail: every file and range that Claude read, edited, wrote or showed you, and your own references, newest first, with a preview. `Enter` opens the place in the code window.

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

`scripts/test` runs the Neovim specs in `tests/`. Its first run downloads the test plugins into `.tests/`, and later runs work offline. `scripts/test-stack` boots the real `init.lua` with your LazyVim config in a child Neovim, with temporary state dirs, and checks that your main Neovim stays unchanged. `scripts/test-ui` embeds anvim with a UI attached and checks the frames it draws: splits that fold back, the cursor after a close, mouse drags, resizes, permission prompts typed at a user's pace, and a selection pinned while Claude reads elsewhere. Run `:checkhealth anvim` when something does not start.

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. See the header of that file for its steps. It shares its UI client, `tools/screen/ui.ts`, with the UI tests. The log is at `~/.local/state/anvim/anvim.log`. A screen tool run keeps its own in a temp dir, and prints its path.
