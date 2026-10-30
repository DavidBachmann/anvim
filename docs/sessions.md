# Sessions and settings

<a id="sessions-and-slash-commands"></a>

Claude Code owns session storage; anvim reads and displays it through the Agent SDK. Sessions are associated with the working directory and the selected account.

## Resume

Start with `anvim -c` for the latest session in the directory, `anvim --resume <id>` for a specific one, or `anvim --resume` to choose. Inside anvim, `/resume` or `<leader>cs` opens the picker. It shows the title or first prompt, last change, size and branch, with a preview.

Choosing a session restarts Claude and reconstructs its transcript. If Claude Code compacted the conversation, history starts at the saved compaction summary. Saved timestamps are shown, but past subagents do not receive live numbers, colors or dots.

## Start over

`/clear` starts a new session, and the view starts over with it. anvim clears the transcript, the agents, the code window's tabs, the `<leader>cf` file list and the `<leader>ct` trail. Claude's count of send-backs starts again, and Codex runs stop. The code window keeps its file, and the prompt history stays.

`/clear` and its alias `/new` keep the [todo list](todos.md). `/reset` does what `/clear` does and also deletes the list. Claude can still change the list until the clear takes effect, which waits for a running turn to end. `/undo-reset` brings the deleted list back.

`<leader>cR` or `:AnvimRestart` restarts Claude in the same session if it exits or hangs, keeping the chosen model and effort. With default effort, the restart uses the level a new session would use.

## Rewind

`/rewind` goes back to before one of your earlier prompts. Pick the prompt, newest first, then choose what to restore:

- **Restore code and conversation** does both, the code first.
- **Restore conversation** resumes the session up to the entry before that prompt. The transcript ends there, and Claude does not see the later turns. The prompt's text goes back into the prompt window, so you can change it and send it again. Images in the prompt come back as their placeholder text, without the images. For the first prompt, a new session starts.
- **Restore code** puts the files back as they were before that prompt ran, and keeps the conversation. Open buffers reload from disk, and a file that the restore deletes leaves the code window.

The code choices show what changes, such as `+12 -3 in 2 files`. They appear only when there is a change to restore. A code restore covers only files that Claude's Write, Edit and NotebookEdit tools changed, in anvim sessions with checkpoints. It does not cover Bash commands, Codex agents, or sessions from before anvim kept checkpoints. Claude Code keeps the rewound turns in its session file, and the next prompt starts a new branch.

`/rewind` works only while Claude and its agents are idle, because a conversation restore restarts Claude and ends running agents. Stop Claude first if a turn is running.

<a id="model-and-effort"></a>

## Model, effort and usage

`/model` or `<leader>cm` opens the model picker; `/model sonnet` switches directly. `/effort` lists the current model's supported levels and `/effort high` selects one for this session. `/effort default` returns to Claude Code's configured level, or the model default; that default follows a model switch. An explicit level remains selected across model switches. `/effort current` asks Claude Code which level applies.

The statusline shows the model and, when supported, its effort. It also shows context-window use, updated at the end of a turn, and the login's email. For accounts with plan limits, `[S27%/W80%]` gives the five-hour and weekly usage, updated at startup, after turns, every five minutes during a long turn, and a minute after a window resets. API-key logins without plan limits show no such meter. Codex agents have separate [model and effort settings](subagents.md#codex-agents).

## Accounts

An account is a Claude Code configuration directory. `default` uses the normal `~/.claude` directory and `~/.claude.json` login; a logged-in `~/.claude-personal` is named `personal`. Startup chooses the first applicable rule:

1. `--account personal` or `ANVIM_ACCOUNT=personal`. An unknown name produces a warning and opens the picker.
2. An existing `CLAUDE_CONFIG_DIR` environment variable.
3. The account remembered for this directory, if it still has a login.
4. A picker, if two or more accounts remain. Closing it without choosing leaves Claude stopped; `/account` opens it again.
5. The only account, or `default` if none is found.

`/account` or `:AnvimAccount` opens the picker; `/account personal` switches directly. The picker shows email and organization and marks the current account. Switching restarts Claude. If both accounts can read the same session, for example through a shared `projects` directory, the session continues when it has a turn; otherwise a new session starts. Switching is unavailable while Claude or an agent is working.

`/account add work2` or the picker's last row creates another account. You can choose to share settings, instructions, skills and sessions via links from `~/.claude`; existing files are not overwritten. Claude Code's login opens in a window. Press `i` to enter a requested code, or `q` to cancel. On success the window closes; on failure it stays open with the output. Switch with `/account work2` afterwards. `:checkhealth anvim` lists accounts and explains the startup choice.

## The Settings window

`/status`, `/usage`, `/context` and `/mcp` open the Settings window. `Tab` changes tabs; `q` or `Esc` closes it. The window does not add its contents to Claude's context.

- **Status** shows Claude Code version, account, config directory, login, organization, email and MCP servers.
- **Usage** shows session cost and tokens, plan limits and reset times, and usage over the last 24 hours and seven days. `/cost` and `/stats` open it too.
- **Context** shows the context grid and its contents, including MCP tools, agents, memory and skills.
- **MCP** lists servers and status. `Enter` shows a server's command and tools; `r` reconnects and `t` toggles it. anvim's own server always runs. Sign in to servers requiring authentication with Claude Code's `/mcp` in a terminal. `/mcp` forms with arguments still run in Claude Code.
- **Chrome** controls the integration described below.

## Processes

`<leader>cp` or `:AnvimProcesses` shows the processes that use the CPU, as htop does. Each row is a group: an app with its helpers, such as Firefox, or the processes with the same name. This anvim's own processes form the `anvim` row. Each Bash call that runs has a row of its own, named after the agent that runs it. A ◆ in the agent's color marks these rows. The rows refresh every 2 seconds while the window is open.

A process whose parent ends moves to launchd, so it leaves anvim's tree. An Android emulator that a Bash command started can run on like this for hours. anvim sets `ANVIM_PID` in its environment, and every process that it starts inherits it. The window looks for that mark when it opens and then every 10 seconds. Each process that has the mark but left the tree gets a ◆ row of its own, such as `qemu-system (3) · started by this anvim`. macOS hides the environment of its own programs, such as `/bin/sleep` and `/bin/zsh`, so such a process stays in the row of its name. A restart sets a new mark, so the processes from before a restart stay in the rows of their names too.

The line above the columns sums up this anvim: its processes, their CPU and memory, the processes outside its tree, and the CPU time of the processes that ended. A process that ends counts in the parent that waited for it. A process that launchd waited for is not counted. The window's own `ps` calls count too, at a small cost while it is open.

CPU is the share of one core, so 100% is one full core and a group can show more. MEM is the memory footprint, the figure of Activity Monitor. macOS gives it only for your own processes, so the processes of other users, such as root, show their RSS, the resident memory. The footprint can be much larger than the RSS, for example 8 GB against 0.9 GB for an emulator.

`x` and `X` send SIGTERM and SIGKILL after a confirm, whose first choice is Cancel. On a group, the signal goes to the processes whose parent is not in the group, such as the main Firefox process. anvim refuses to signal itself: use `:AnvimRestart` or `:q`. It also refuses to signal the processes above its terminal UI, such as the shell and the terminal app, because their end would end anvim too. The rows of the processes outside the tree accept signals.

## Claude in Chrome

Claude in Chrome lets Claude use Chrome through the Claude extension. It requires a claude.ai login. Start with `--chrome` or `--no-chrome` to override Claude Code's “Enabled by default” setting. `/chrome` opens the Chrome tab, where `Enter` runs the selected action: install or manage the extension, choose a browser, reconnect, or change the default for future sessions. Reconnecting can restart Claude in the same session with Chrome enabled.

The extension's site permissions govern browsing, clicking and typing. A session that **starts in bypass mode** tells the extension to skip those checks, allowing actions on any site without asking. Start with `--mode default` to retain the checks. See [permissions](permissions.md) for the other implications of bypass mode.

## Other slash commands

Commands not handled by anvim run in Claude Code and show their output in the transcript. Completion includes supported Claude Code commands and commands from your projects, plugins and skills. `Enter` completes and sends a command; if it needs an argument, it completes without sending.

Some commands require Claude Code's terminal, including `/color`, `/focus` and `/doctor`; anvim displays a notice if you type them. Other unavailable terminal-only commands may be rejected by Claude Code. Paid cloud reviews, including `/ultrareview` and `/code-review ultra`, must also run in Claude Code's terminal.
