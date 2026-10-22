# anvim

anvim is a read-only Neovim for watching Claude Code work. You read and point; Claude writes, and its edits stream into your buffers as Claude generates them. It runs the real Claude Code engine through the Agent SDK, so your login, CLAUDE.md files, skills, MCP servers, hooks and settings work as they do in Claude Code. anvim is a personal tool shared with colleagues, with no releases and no compatibility promise.

## Requirements

- Neovim 0.12 or newer, git and [Bun](https://bun.sh)
- A C compiler, curl, tar and gzip, to build the treesitter parsers and to install the language servers
- Node.js with npm, for the TypeScript and JSON language servers
- [ripgrep](https://github.com/BurntSushi/ripgrep), for grep
- A [Nerd Font](https://www.nerdfonts.com) in the terminal, for the icons
- Claude Code, logged in (`claude /login`)
- Google Chrome, only for the screen tool

`scripts/install` checks the tools. It stops without Neovim, git or Bun, and warns about the others.

## Install

Clone the repo. Then, from its root:

```sh
scripts/install
mkdir -p ~/.local/bin
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

If `~/.local/bin` is not on your PATH, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile, such as `~/.zshrc`.

`scripts/install` installs the sidecar's packages from `sidecar/bun.lock`, and anvim's plugins with lazy.nvim at the commits in the repo's `lazy-lock.json`. With mason, it installs the tree-sitter CLI and the language servers for Lua, TypeScript and JSON. Then it builds the treesitter parsers. The first run takes about half a minute on a fast network. A second run installs only what is missing, and takes less than a second. The link puts `anvim` on your PATH, and any dir on your PATH works for it. `scripts/install` prints these steps when `anvim` is not on your PATH yet.

anvim brings its own Neovim config, and reads and writes nothing under your main Neovim's `~/.config/nvim` and `~/.local/share/nvim`. The two never share a plugin or a file.

## The first start

```sh
anvim ~/dev/project
```

anvim opens three columns: the explorer, the code and Claude. The cursor is in the prompt at the bottom right, in normal mode. Press `i`, type a question and press `Enter`. Claude asks before it edits a file or runs a command (see [Permissions](#permissions)). If `scripts/install` never ran, `anvim` runs it first.

## Update

```sh
git pull
anvim
```

When the repo's `lazy-lock.json` or `sidecar/bun.lock` changed since the last install, or the code that lists the mason packages and the parsers, `anvim` runs `scripts/install` before it starts. The install moves each plugin to the repo's commit, also back to an older one. If it fails, for example without a network, anvim warns, starts with the plugins it has, and tries again at the next start. A plugin of your own specs that fails to install only gets a warning. With `ANVIM_NO_INSTALL=1`, anvim installs nothing, not even at start.

Nothing that anvim does writes a tracked file, so `git pull` always works. `:Lazy update` in anvim updates the plugins in the install dir only. The next install after a pull that changes the repo's lockfile brings anvim's own plugins back to the repo's commits.

## Your own plugins

Your own specs go in `~/.config/anvim/lua/plugins/*.lua`. They load after anvim's, as lazy.nvim specs. lazy.nvim installs their plugins at the next start, and keeps their commits in the install dir's lockfile, `~/.local/share/anvim/lazy-lock.json`, never in the repo. Without a colorscheme of your own, anvim uses tokyonight. To bring one:

```lua
-- ~/.config/anvim/lua/plugins/colorscheme.lua
return {
  {
    "rose-pine/neovim",
    name = "rose-pine",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("rose-pine")
    end,
  },
}
```

## Files and uninstall

anvim's Neovim runs with `NVIM_APPNAME=anvim`, so its files are in dirs of their own:

- `~/.local/share/anvim`, the install dir: the plugins in `lazy/`, the parsers in `site/`, mason's packages in `mason/`, lazy.nvim's lockfile and the stamp of the last install. `ANVIM_INSTALL_DIR` puts it elsewhere.
- `~/.local/state/anvim`: the log, undo history, past prompts, the choices that you made with `<leader>u` keys, and the language servers' logs.
- `~/.cache/anvim`: caches.
- `~/.config/anvim`: your own specs, if you have any.
- `sidecar/node_modules` in the repo.

The first four follow `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and `XDG_CONFIG_HOME`. Claude Code keeps its sessions in `~/.claude`, as for the CLI. To uninstall anvim, remove its dirs and the link, and then the repo:

```sh
rm -rf ~/.local/share/anvim ~/.local/state/anvim ~/.cache/anvim ~/.config/anvim ~/.local/bin/anvim
```

## Use

```sh
anvim [--model <model>] [--effort <level>] [--mode <mode>] [--no-sandbox] [-c | --continue | -r | --resume [id]] [dir] [nvim args...]
anvim --model haiku ~/dev/project
anvim --effort high ~/dev/project               # low, medium, high, xhigh or max
anvim --mode default ~/dev/project              # ask before Claude edits a file or runs a command
anvim --no-sandbox ~/dev/project                # let Bash commands write anywhere, and start in default mode
anvim -c ~/dev/project                          # go on with the latest session there
anvim --resume ~/dev/project                    # pick a session to go on with
```

The screen has three columns: the explorer, code, and Claude. `<leader>e` hides the explorer, and so do `q` and `Esc` in its list. The code window then takes its columns. `<leader>e` again opens the explorer with the cursor in its list. The explorer shows again at the next start. `<leader>uH` swaps the sides, so Claude is on the left and the explorer on the right. The explorer is 30 columns wide. While it has focus, it widens over the code window to fit its names, and the code window stays where it is. `<leader>ue` turns off this auto-minimize: the explorer then always fits its names, up to 40% of the screen, and the code window gives it the columns. anvim remembers both choices for the next start. anvim starts with the cursor in the prompt at the bottom right, in normal mode, so your first keys can move around. Press `i` to type. While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Claude often reads with Bash, so `cat`, `head`, `tail`, `sed -n` and `nl` open their files too, and a `grep -n` opens at its first hit. Move the cursor anywhere else to take control and review code. The footer under the prompt then shows where Claude is, such as `⏺ Claude at stream.lua:40 +2`, and `<leader>j` jumps there. In the prompt it says `◉ following`. In a narrow column it drops the words, as in `⏺ stream.lua:40 +2`, and when even that does not fit, the statusline shows it.

Follow mode is a mode of its own, next to Vim's normal, insert and visual mode. The mode block at the left of the statusline reads `FOLLOW` in Claude's orange, also while you type in the prompt. In follow mode the code window has no line numbers, so the text that Claude writes never moves right when a file grows past 9 or 99 lines. In review mode the block shows Vim's mode, and the code window has the line numbers that your config sets. A `:set number` there lasts until you go back to the prompt. A picker or the key view that opens over the prompt keeps follow mode. The compose window counts as the prompt, and a pinned selection means review mode.

File buffers are read-only. `:w` does nothing but say so, and format on save never runs. Claude makes every change, and buffers reload when files change on disk. Long lines in the code window wrap, and `<leader>uw` turns that off for code. anvim remembers the choice for the next start. Markdown and text files always wrap, with no spell checking.

A `:` command line opens in a window over the code, titled "Command line", so it never looks like the prompt. Search with `/` and `?` opens there too, titled "Search". No row at the bottom of the screen is kept for them: messages show for a few seconds at the bottom right, and the statusline shows a macro recording.

The cursor moves between the code window and the prompt in one step: `Ctrl-W l` or `Ctrl-L` from any row of the code window, and `Ctrl-W h` or `Ctrl-H` back. Moving into the prompt leaves you in normal mode. Only insert commands start typing: `i`, `a` and the others in the prompt. In a file buffer, `i`, `a`, `I`, `A`, `o` and `O` go to the prompt and type where you stopped. The transcript takes no focus. A window key that would land on it skips it, a click on it goes to the prompt, and the mouse wheel scrolls it from anywhere. It stops where the last line reaches the bottom of the window. New output keeps the transcript at its end, unless you scrolled up. Then it stays put until you scroll back down or send a prompt. To yank or search the transcript, enter read mode with `<leader>cr`, or drag across it with the mouse.

For a long prompt, `Ctrl-G` in the prompt opens it in a large window in the middle of the screen, as Claude Code's `Ctrl-G` opens it in your editor. There `Enter` adds a line, and `@` and `/` complete as in the prompt. `Ctrl-G` again, `:wq` or `ZZ` puts the text back in the prompt, at the same place and in the same mode: after `Ctrl-G` while typing you go on typing, and after `:wq` you are in normal mode. `:w` puts it there and keeps the window open, and `:q!` drops your changes. Leaving the window keeps the text too. Follow mode goes on while you write.

Only one window shows files, so anvim always knows which file you are looking at. The bar at the top of the code window names the file, relative to the working directory, and says `(writing)` while Claude writes a new file. A split, a picker's split action or `:diffsplit` opens the file in the code window instead. Help, quickfix, terminal and plugin windows open as usual. If you close the code window, the transcript or the prompt, anvim opens it again. `:q` in any of them quits anvim, also when other tabs are open.

Claude can also use your editor. It points at code with `show_user`, which marks a range and puts a short note above it until your next prompt. It asks the language servers that run in anvim for diagnostics, definitions, references, hover text and symbols, so it greps less. These tools work in every permission mode, so they read only files inside the directory that anvim opened. `show_user` can point at any file, because its answer holds no file text.

## Keys

`<leader>` is Space. `<leader>?` shows every key of anvim in one view, grouped by where it works, as in the tables below. In the prompt, `?` in normal mode shows it too. While you type, `?` shows it only when the prompt is empty and no request waits. Otherwise it types a `?`. The footer says `? for shortcuts` then, unless it shows a mode. A dim tag names the mode of a key that does not work in normal mode, such as `insert` or `visual`. `j` and `k` scroll the view when it does not fit. `q`, `Esc` or `:q` closes it, and the cursor goes back where it was, in the same mode. Vim's own keys work as usual.

The keys for reading sit where LazyVim puts them, so a LazyVim user finds them at once. Keys that edit, such as code actions, rename and window splits, are left out. So are Neovim's own keys that only change text: `gc` and `gcc`, which comment, `[<Space>` and `]<Space>`, which add blank lines, and `&`, which repeats a substitution. In operator-pending mode `gc` stays, because it selects a comment: `cgc` points Claude at one. In the explorer, the keys that add, delete, rename, copy, move and paste files do nothing, and so does `Ctrl-C`, which would change the working directory. In the git logs, `Enter` goes to the commit's diff and never checks out. Git status and the diff picker stage with `Tab`, but cannot restore.

### Everywhere

| Key | Action |
| --- | --- |
| `<leader>?` | Show every key of anvim |
| `Ctrl-H`, `Ctrl-J`, `Ctrl-K`, `Ctrl-L` | Go to the window on the left, below, above or on the right |
| `Shift-H`, `Shift-L` | Previous and next buffer |
| `j`, `k` | Move by screen line in wrapped text, by line with a count |
| `Esc` | Clear the search highlight |
| `<leader><space>`, `<leader>/`, `<leader>,` | Find files, grep, buffers |
| `<leader>fr` | Recent files |
| `<leader>e` | Toggle the explorer |
| `<leader>sw` | Grep the word under the cursor, or the selection |
| `<leader>ss`, `<leader>sS` | Symbols of the file, of the workspace |
| `<leader>sd`, `<leader>sD` | Diagnostics of the workspace, of the file |
| `<leader>sh` | Help pages |
| `<leader>gs`, `<leader>gd` | Git status, git diff by hunk |
| `<leader>gl`, `<leader>gf`, `<leader>gb` | Git log, the file's history, the line's history |
| `<leader>uw`, `<leader>ud` | Toggle wrap in the code window, toggle diagnostics |
| `<leader>uH` | Toggle Claude on the left and the explorer on the right |
| `<leader>ue` | Toggle explorer auto-minimize |
| `q` | Close a help, quickfix or info window |

### Code window

| Key | Action |
| --- | --- |
| `i`, `a`, `I`, `A`, `o`, `O` | Go to the prompt and type where you stopped |
| `c` in visual mode | Put a reference to the selected lines in the prompt |
| `c{motion}`, `cc` | Put a reference to the lines of the motion, or to the current line, in the prompt |
| `Ctrl-L` in visual mode | Go to the prompt and keep the selection |
| `gd`, `gr`, `gI`, `gy`, `gD` | Definition, references, implementation, type definition, declaration, in a buffer with a language server |
| `K` | Hover |
| `gO` | List the file's symbols |
| `]]`, `[[` | Next and previous reference to the word under the cursor, in a buffer with a language server |
| `]d`, `[d`, `]D`, `[D` | Next, previous, last and first diagnostic |
| `Ctrl-W d` | Show the diagnostics at the cursor |
| `]h`, `[h`, `]H`, `[H` | Next, previous, last and first hunk |
| `<leader>ghp`, `<leader>ghb` | Preview the hunk, blame the line |
| `gx` | Open the path or link under the cursor with the system app |
| `ii`, `ai` | The scope inside its edges, the scope with its edges, as text objects: `cii` points Claude at a block |
| `[i`, `]i` | Go to the scope's top and bottom edge |

### Prompt

| Key | Action |
| --- | --- |
| `Enter` | Send |
| `Shift-Enter`, `Alt-Enter` | New line, in insert mode |
| `Esc`, a pause, `Esc`, in normal mode | Stop Claude |
| `Ctrl-C`, `:AnvimStop` | Stop Claude at once |
| `Shift-Tab` | Cycle the permission mode |
| `Ctrl-X` | Unpin the selection |
| `Ctrl-G` | Write the prompt in a large window |
| `Up` on the first line, `Down` on the last | Go back and forth through past prompts, in insert mode |
| `Ctrl-P`, `Ctrl-N` | Go back and forth through past prompts, in normal mode |
| `Ctrl-U`, `Ctrl-D`, `Ctrl-B`, `Ctrl-F` | Scroll the transcript, in normal mode |
| `PageUp`, `PageDown` | Scroll the transcript |
| `@`, `/` | Complete a file, or a slash command at the start, in insert mode |
| `?` | Show every key of anvim, in normal mode or in an empty prompt |
| `Ctrl-Space`, `Ctrl-E` | Show and close the completion menu, in insert mode |
| `Ctrl-N`, `Ctrl-P`, `Up`, `Down` | Next and previous item, while the menu is open |
| `Ctrl-Y`, `Enter` | Accept the highlighted item. A word menu that opens as you type highlights none, so `Enter` sends |

### Compose window

| Key | Action |
| --- | --- |
| `Ctrl-G` | Put the text back in the prompt and go there |
| `:w` | Put the text in the prompt, and keep the window open |
| `:wq`, `ZZ` | Put the text in the prompt, and close the window |
| `:q!` | Drop the changes |

### Explorer

| Key | Action |
| --- | --- |
| `@` | Put a reference to the file in the prompt |
| `Ctrl-H`, `Ctrl-L`, `Ctrl-W h`, `Ctrl-W l` | Go to the code window |
| `?` | Show the explorer's own keys |

### Transcript and read mode

| Key | Action |
| --- | --- |
| `q`, `Esc` | Go back to the prompt |
| `i`, `a`, `I`, `A`, `o`, `O` | Go back to the prompt and type |
| Mouse drag | Select text, in read mode |
| Mouse wheel | Scroll the transcript, from any window |

### Permission requests

These keys work in the prompt, in normal mode, while Claude waits for your answer.

| Key | Action |
| --- | --- |
| `1` to `9` | Choose that option |
| `Enter` | Choose the highlighted option |
| `j`, `k` | Move to the next or previous option |
| `Esc`, a pause, `Esc` | No |

### Claude and its agents

| Key | Action |
| --- | --- |
| `<leader>j`, `<leader>cj` | Jump to where Claude, or the focused subagent, is |
| `<leader>c1` to `<leader>c4` | Focus the subagent with that number, so follow mode follows it |
| `<leader>c0` | Focus Claude, the main agent, again |
| `<leader>ca` | Pick an agent to focus, with its place in the preview |
| `<leader>ct`, `:AnvimTrail` | Pick a place from Claude's trail |
| `<leader>cr`, `:AnvimTranscript` | Read the transcript: put the cursor in it to yank and search |
| `<leader>cy` | Yank Claude's last reply to the clipboard |
| `<leader>cs`, `:AnvimSessions` | Resume a session of this directory |
| `<leader>cm`, `:AnvimModel` | Choose Claude's model |
| `<leader>cR`, `:AnvimRestart` | Start Claude again, in the same session |

## Sessions

Claude Code saves every session, and anvim reads them through the Agent SDK. `anvim -c` goes on with the latest session in the directory, and `anvim --resume <id>` with that one. `--resume` without an id opens the session picker at start. In anvim, `<leader>cs` or `/resume` opens it: each session shows its title or first prompt, when it changed, its size and its branch, with details in the preview. Choosing one starts Claude again in that session and draws its past in the transcript, as it looked live. A session that Claude Code compacted starts at the compaction, because Claude Code keeps only the summary. Saved sessions do not keep what went with each prompt, so a resumed transcript shows no `⎿  ⧉` lines. A background subagent's end shows as it did live, but past subagents get no numbers, colors or dots.

`/clear` starts a new session and empties the transcript. `<leader>cm` or `/model` lists the models that Claude Code offers, and the footer shows the one you choose. `/model sonnet` switches at once. `/effort` lists the effort levels of the current model, and `/effort high` sets one at once, for this session only, without a change to your settings. `/effort default` gives the effort that a new session would have: the level in your Claude Code settings for the model, else the model's. The default follows a model switch, and a level that you chose stays, as in Claude Code. `/effort current` asks Claude Code which level applies. The footer shows the level that the session uses next to the model, as in `Haiku 5.5 · high`, and no level for a model without effort levels. `<leader>cR` or `:AnvimRestart` starts Claude again when it exited or hangs, in the same session, and keeps the model and effort you chose. A restart with the default effort starts as a new session would.

Other slash commands run in Claude Code, and their output shows under them, such as `/usage` with your plan's limits, or `/context`. The completion menu lists the commands that work here: Claude Code's own, which it lists for the Agent SDK, and every command of yours, your projects, plugins and skills. It leaves out the few that work only in Claude Code's terminal, such as `/color`, `/focus` and `/doctor`. Typed anyway, they get a notice and go nowhere. anvim also starts no paid cloud review, so `/ultrareview` and `/code-review ultra` work only in Claude Code. Claude Code answers a terminal-only command that it does not list, such as `/help` or `/status`, with "isn't available in this environment". As in Claude Code, `Enter` on a slash command in the completion menu completes it and sends it. A command that needs an argument, such as `/batch <instruction>`, is only completed, so you can type the argument.

Your prompts are saved per directory, the last 200, in anvim's state dir. `Up` on the first line of the prompt goes back through them, and `Down` on the last line comes forward again, back to what you were typing. While the completion menu is open, `Up` and `Down` move in the menu instead.

When Claude is done, or needs your answer, while the terminal does not have focus, anvim posts a desktop notification. Inside cmux, it uses `cmux notify` for its own pane. Elsewhere it writes OSC 9, which many terminals show as a notification. It never notifies while you look at it.

## The transcript

Claude's replies render their markdown, as in Claude Code: bold, inline code and links show without their markers, and code blocks have syntax colors. Tool lines, their results and your prompts show as they are, so a command such as `grep '**' *.lua` keeps its stars. Paths under the working directory show short: `Bash(find . -name '*.lua')`.

Claude's todo list stays at the end of the transcript, under the newest output, while it has open items. Claude Code keeps it with TodoWrite, or with TaskCreate and TaskUpdate. For its newest models, it offers these tools only when `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set. The item in progress is bold, and the spinner names it. Once every item is done, the list stays in the transcript where it was. A subagent shows its last three tool calls under its line while it works, and then a summary such as `Done (12 tool uses · 24.1k tokens · 1m 2s)`. A compaction shows as a notice with the tokens before and after. When Claude is idle, the line above the prompt shows the last turn's time and cost, and how full the context window is.

## Subagents

Claude can start subagents, such as Explore, and several at once. Each running subagent gets a number from 1 to 4 and a color of its own, and anvim names it by its type and that number, such as `Explore 2`. The bullet of its line in the transcript has that color while it runs. The footer has a dot in each running subagent's color, and their count: `⏺⏺⏺ 3 agents`. In the explorer, an agent's dots in its color show where it works, up to three agents and then `+`. A `⏺` marks the file that the agent reads or writes now, and a `•` marks each other file that it wrote to. A closed folder shows each agent once: a `⏺` when the agent's current file is below it, else a `•`. A subagent's dots go when it ends, and Claude's own dots last until its turn ends.

Follow mode follows one agent at a time, at first Claude itself. `<leader>c2` focuses subagent 2, and `<leader>c0` focuses Claude again. `<leader>ca` lists Claude and the running subagents, with what each one does, its tool uses and its place, which the preview shows. While a subagent has focus, the code window goes where that subagent reads and edits, and the other agents' moves leave it alone. The footer says `◉ following Explore 2` in the agent's color, the agent's dot there is `◉`, and its line in the transcript ends in `◉ focused`. Claude Code sends a subagent's edits whole, not as they are generated. So while you follow a subagent, anvim types its edits into the code window at a steady pace, in 2 s at most, before the file changes. The other agents never wait for that. When the subagent ends, focus goes back to Claude, and the transcript says so. A permission request from a subagent names it in its color, such as `Edit file · Explore 2 (Find x)`.

A background subagent keeps working after Claude's turn ends. Its line says `Backgrounded agent`, lists its newest tool calls, and keeps its color and its number until it ends. Then its line shows its totals, and a row at the end of the transcript says `Agent "Find x" finished`, with its summary. When Claude is idle, it replies to each end in a turn of its own, as in Claude Code.

## Pointing

Claude always knows what you look at. Each prompt tells it the file in the code window, the cursor line and the visible lines, so "What does this file do?" needs no reference. The footer under the prompt shows what the next prompt carries: `⧉ In stream.lua`.

Select lines in the code window, in any visual mode, and go to the prompt: `Ctrl-L`, `Ctrl-W l`, a click, or `Esc` and then `i`. The selection stays highlighted, and the footer says `⧉ 19 lines selected`. Your next prompt carries it, and sending that prompt unpins it. It also goes when you move on: move the cursor in the code window, open another file, start a new selection, or press `Esc` in normal mode there. Scrolling keeps it. `Ctrl-X` in the prompt unpins it. When Claude edits the file, the selection goes, because its text changed. A long selection gives Claude its line numbers and its first 2000 characters, as Claude Code's IDE integrations do. Slash commands run in Claude Code and carry no editor context.

While a selection is pinned, follow mode waits, so the code window keeps what you point at. The footer says so, for example `⏸ pinned · Claude at stream.lua:40 +2`. Once the prompt is sent or the pin goes, the code window catches up with Claude, also with a file that Claude is still writing. `<leader>j` unpins and goes to Claude, or to the focused subagent, at once.

References are text in the prompt, in the form `@path#L12-30`, and you can write several. In a file buffer, `c` puts one in the prompt and goes on typing after it: `c` in visual mode for the selection, `c{motion}` for the lines of a motion such as `cip` or `cj`, and `cc` for the current line or, with a count, more lines. Read-only buffers leave `c` free, so read it as "change this, Claude". `@` in the explorer references whole files and leaves the cursor after them, in normal mode. In the prompt, `@` completes files and directories, and `/` at the start completes slash commands. The transcript shows what went with each prompt, dimmed under it: `⎿  ⧉ stream.lua#L12-30`.

`<leader>ct` opens Claude's trail: every file and range that Claude read, edited, wrote or showed you, and your own references, newest first, with a preview. `Enter` opens the place in the code window.

## Permissions

anvim starts in bypass mode, with the sandbox on: Claude edits files and runs commands in the project without asking. The sandbox keeps its Bash commands from writing outside the project, and anvim still asks where the sandbox has gaps (see [The sandbox](#the-sandbox)). Without a sandbox, anvim starts in default mode instead, unless you chose a mode. Start it with `--mode default`, `--mode acceptEdits` or `--mode plan` for another mode. Default mode asks before Claude edits a file or runs a command, as Claude Code does, unless your Claude Code settings allow it. To start in another mode by default, put `export ANVIM_MODE=default`, for example, in your shell profile. `--mode` wins over it. `Shift-Tab` in the prompt cycles default, accept edits and plan mode, plus bypass when anvim started in it. The footer shows the mode only while it differs from the one anvim started in, such as `⏵⏵ accept edits on`, or `⏵ manual mode on` for default mode. Plan mode always shows.

When Claude needs your yes, the request appears at the bottom of the Claude column, as in Claude Code. An edit streams into the code window before the request opens, so you see the change before you answer. If you say no, the buffer shows the file on disk again. Claude's questions and its plan, when it wants to leave plan mode, appear the same way. If your cursor is outside the prompt, anvim leaves it there, posts a notification and shows "⏺ Claude is waiting" in the statusline. A request brings the transcript to its end, even if you scrolled it up. In read mode the transcript stays where you read, and it goes to the request when you leave read mode. `Esc` there takes you back to the prompt and answers nothing. A choice key never answers a request that is out of view: it brings the request into view instead.

The keys that answer are under [Permission requests](#permission-requests).

While a request waits, normal mode in the prompt is for choosing. Typing your prompt never answers: if you are typing when a request opens, you keep typing, digits are text, and `Enter` keeps your prompt without sending it or answering. Press `Esc`, then choose. `Enter` chooses the highlighted option. The line above the prompt says which keys answer, and in insert mode it starts with `esc to leave insert mode`. A choice also does nothing within 0.4 s of the request opening or of the last character you typed. Going to the prompt while Claude waits leaves you in normal mode. After you answer, the prompt goes back to insert mode where you stopped typing, if you were typing.

`Esc` in normal mode in the prompt answers No, or stops Claude while Claude works. It acts only when you press it twice. The first press only arms it. The line above the prompt then says in red what the next press does, such as "esc again to stop Claude". The request shows that choice in red too. Press `Esc` again after a pause of at least 0.4 s and within 3 s. A press within the pause does nothing and starts the pause again, so a burst of `Esc` presses never stops Claude. A busy change, a new or changed request, any other key, leaving the prompt and the end of the 3 s limit take the red text away. The next `Esc` then starts over. `Ctrl-C` stops Claude at once.

"No, and tell Claude what to do differently", "No, keep planning" and a question's "Other" take typed text. `Enter` sends it, and `Esc` twice goes back to the options. Your draft prompt comes back afterwards. If Claude Code names a path outside the working directory, the request shows it. "Yes, and don't ask again" names the rules that Claude Code suggests, such as `Bash(npm test:*)`, and applies them all. Claude Code saves project rules in the project's `.claude/settings.local.json`. Plan approval offers Claude Code's choices: accept edits or manual approval, with bypass in place of accept edits when anvim started in bypass mode. The plan stays in the transcript. A multi-select question has a Submit option after its choices.

## The sandbox

anvim runs Claude's Bash commands in Claude Code's own sandbox: Seatbelt (`sandbox-exec`) on macOS, and bubblewrap on Linux. A command can write only in the project, in the sandbox's temp dir, `$TMPDIR`, and in the caches of npm, bun and go build. So an accidental `rm -rf ~/something` fails with "Operation not permitted". Commands can still read every file. The sandbox catches accidents. It does not stop an agent that tries to get out, and it does not protect the project itself, so keep your work in git. In default mode, Claude asks before a command as it does without the sandbox: read-only commands such as `ls` and `cat` run without a prompt, and the others ask. Bypass mode runs commands without asking, but still in the sandbox.

When you start anvim in a subdirectory of a git repo, the sandbox lets commands write in the repo's root too, so that `git add` and `git commit` work. Claude Code keeps `.git/config` and `.git/hooks` read-only, so `git config` fails. This does not apply in a linked worktree or a submodule, whose git dir is elsewhere.

A command that connects to a new host asks first, in default mode: "Network access" names the host. "Yes, and don't ask again" saves a `WebFetch(domain:<host>)` rule in the project's `.claude/settings.local.json`. That rule also lets Claude's WebFetch tool reach the host without a prompt. In bypass mode, a command can connect to any host without asking.

The sandbox has gaps, and anvim asks at each of them, in every mode, bypass mode too. The prompt says why in a yellow line, and it has no "don't ask again", because anvim would ask again anyway:

- When a command fails in the sandbox, Claude often runs it again outside the sandbox, with `dangerouslyDisableSandbox`. anvim asks first, under the title "Bash command (unsandboxed)", with the line "runs outside the sandbox".
- A command that matches `sandbox.excludedCommands` in a settings file runs outside the sandbox, and a repo's own `.claude/settings.json` can list such commands. anvim asks: "runs outside the sandbox (excluded command)". It reads the list from Claude Code for each command. It asks for any command line in which a command, after quotes, `VAR=value` words and wrappers such as `timeout` or `sudo`, starts with an entry's words before its first `*`: with `npm run *`, `npm run build` asks and `npm test` does not. That is more often than Claude Code lets a command out, because Claude Code's parser has forms that anvim cannot follow.
- Claude's Edit and Write tools run outside the sandbox. anvim asks for an edit outside the trusted dirs: "outside the trusted dirs: ~/notes.txt". Default mode asks there anyway, and it stays one prompt. The trusted dirs are the project, the dirs in `sandbox.filesystem.allowWrite` (the git root above the project and the npm, bun and go build caches among them), the sandbox's temp dir `/tmp/claude-<uid>` (or `claude-<uid>` in `$CLAUDE_CODE_TMPDIR`), and `projects/` and `plans/` in Claude Code's config dir, which hold its memory and plans. Plain `/tmp` asks. Symlinks count where they lead, so a link in the project that points to `~` asks too.
- An edit of the project's `.claude/settings.json` or `.claude/settings.local.json`, or of those in the git root, asks: "changes the sandbox's settings". These files can widen the sandbox, for example with `allowWrite` or `excludedCommands`.
- An edit of a file that tools read as config and run, from Claude Code's own list, asks: "changes a config that runs outside the sandbox". The list has dirs such as `.git`, `.claude`, `.vscode` and `.husky`, and files such as `.mcp.json`, `.envrc`, `.npmrc`, `.zshrc` and `lefthook.yml`. An MCP server in `.mcp.json` runs outside the sandbox, and a git hook in `.git/hooks` runs when you use git in your own terminal. Default mode asks for these anyway, and it stays one prompt. As in Claude Code, edits in `.claude/worktrees`, where Claude's worktree agents work, do not ask. A hook script that your settings name in another place stays a gap: an edit of it runs outside the sandbox at the next hook.

A model sometimes takes one of these ways by accident, when a way inside the sandbox exists. So anvim does not ask at the first such call of Claude or of each subagent. It sends the call back to Claude with a hint. The hint says that anvim has not asked you yet, and it names a way that needs no prompt. It also says that Claude can send the same call again to get your answer. After that one send-back, each such call of that agent asks you. The transcript shows the call's result as "Sent back to Claude: runs outside the sandbox". An agent's log names the agent. `/clear` starts over for Claude. anvim writes each send-back, and each later prompt of that agent, to `~/.local/state/anvim/anvim.log`. These lines start with `send-back:`.

`--no-sandbox` turns these prompts off too.

On Linux, the sandbox needs `bwrap` (from bubblewrap) and `socat`. Without them, anvim warns, commands run without the sandbox, and anvim runs in default mode, so Claude asks before it runs a tool. The same happens when Claude Code finds that the sandbox cannot start. `--no-sandbox` also starts anvim in default mode, without a warning. A mode that you chose with `--mode`, `ANVIM_MODE` or your own spec stays: with `--mode bypassPermissions`, commands then run anywhere without asking. `:checkhealth anvim` says whether the sandbox is on, and which mode anvim starts in and why. `anvim --no-sandbox`, or `ANVIM_SANDBOX=0`, turns it off, also when a settings file turns it on. A spec of your own can set the anvim plugin's `sandbox` option to `false` too.

Some tools write to caches outside the project, and fail in the sandbox. anvim lets the sandbox write the caches of npm (`~/.npm`, also for `npx`), bun install (`~/.bun/install/cache`) and go build (`~/Library/Caches/go-build` on macOS, `~/.cache/go-build` on Linux). In bypass mode, Claude's edits there do not ask either. These caches hold code that runs later outside the sandbox, such as the packages in `~/.npm/_npx`, so a command in the sandbox can change what runs outside it. That fits the sandbox's job: it catches accidents, not an agent that tries to get out. For another tool, add its dir to your own Claude Code settings, `~/.claude/settings.json`. These lists add to anvim's sandbox options:

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": ["~/.cache/<tool>"]
    }
  }
}
```

Each entry lets every sandboxed command write there. Two more keys in `sandbox` make other tools work on macOS, at a cost:

- `"network": { "allowUnixSockets": ["<path>"] }`, with the real path of `$SSH_AUTH_SOCK`, such as `/private/var/run/com.apple.launchd.../Listeners`, makes `ssh-add` work. Every sandboxed command can then sign with your SSH keys, and the path changes when you log in again. git over ssh works without it.
- `"enableWeakerNetworkIsolation": true` makes `gh` and `pip` work, because they check TLS certificates through the system's trust service. The Agent SDK's docs say that this opens a possible path for data to leave the machine.

## Record and replay

```sh
ANVIM_RECORD=session.jsonl anvim --model haiku   # save every event
ANVIM_REPLAY=session.jsonl anvim                 # play it back, with no API cost
```

Each prompt you send during a replay plays the next recorded turn. The work of a background subagent plays on after its turn ends.

## Development

These must pass before a commit. The Lua checks need `stylua` and `selene` on your PATH.

```sh
cd sidecar && bunx tsc --noEmit && bun test
scripts/test
scripts/test-stack
scripts/test-ui
stylua --check . && selene .
cd tools/screen && bunx tsc --noEmit
```

The repo's `lazy-lock.json` holds the commits of anvim's own plugins, and only `scripts/update-plugins` writes it:

```sh
scripts/update-plugins               # every plugin
scripts/update-plugins snacks.nvim   # only these
```

It first brings your install dir to the repo's commits, and then updates the plugins there to their newest commits. It reads none of your own specs, so their plugins stay out of the repo's lockfile. Commit the new lockfile after the tests pass. After a pull, each colleague's next start installs the new commits.

Each test script first runs `scripts/test-deps`. It installs anvim's plugins at the lockfile's commits, with the same code as `scripts/install`, and mason's lua-language-server, into `.tests/anvim`. Its first run needs the network, and later runs work offline. `scripts/test` runs the Neovim specs in `tests/`, with test plugins of its own in `.tests/`. `scripts/test-stack` boots the real `init.lua` in a child Neovim, with the plugins from `.tests/anvim` and temporary state dirs. It checks that anvim installs and writes nothing there, nor in your main Neovim's dirs. `scripts/test-ui` embeds anvim with a UI attached and checks the frames it draws: splits that fold back, the cursor after a close, mouse drags, resizes, permission prompts typed at a user's pace, and a selection pinned while Claude reads elsewhere. Run `:checkhealth anvim` when something does not start.

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. It boots the plugins in `.tests/anvim`, as the UI tests do. See the header of that file for its steps. It shares its UI client, `tools/screen/ui.ts`, with the UI tests. The log is at `~/.local/state/anvim/anvim.log`. A screen tool run keeps its own in a temp dir, and prints its path.
