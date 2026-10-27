# Sessions and settings

<a id="sessions-and-slash-commands"></a>

Claude Code owns session storage; anvim reads and displays it through the Agent SDK. Sessions are associated with the working directory and the selected account.

## Resume

Start with `anvim -c` for the latest session in the directory, `anvim --resume <id>` for a specific one, or `anvim --resume` to choose. Inside anvim, `/resume` or `<leader>cs` opens the picker. It shows the title or first prompt, last change, size and branch, with a preview.

Choosing a session restarts Claude and reconstructs its transcript. If Claude Code compacted the conversation, history starts at the saved compaction summary. Saved timestamps are shown, but past subagents do not receive live numbers, colors or dots. `/clear` starts a new session and clears the transcript.

`<leader>cR` or `:AnvimRestart` restarts Claude in the same session if it exits or hangs, keeping the chosen model and effort. With default effort, the restart uses the level a new session would use.

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

## Claude in Chrome

Claude in Chrome lets Claude use Chrome through the Claude extension. It requires a claude.ai login. Start with `--chrome` or `--no-chrome` to override Claude Code's “Enabled by default” setting. `/chrome` opens the Chrome tab, where `Enter` runs the selected action: install or manage the extension, choose a browser, reconnect, or change the default for future sessions. Reconnecting can restart Claude in the same session with Chrome enabled.

The extension's site permissions govern browsing, clicking and typing. A session that **starts in bypass mode** tells the extension to skip those checks, allowing actions on any site without asking. Start with `--mode default` to retain the checks. See [permissions](permissions.md) for the other implications of bypass mode.

## Other slash commands

Commands not handled by anvim run in Claude Code and show their output in the transcript. Completion includes supported Claude Code commands and commands from your projects, plugins and skills. `Enter` completes and sends a command; if it needs an argument, it completes without sending.

Some commands require Claude Code's terminal, including `/color`, `/focus` and `/doctor`; anvim displays a notice if you type them. Other unavailable terminal-only commands may be rejected by Claude Code. Paid cloud reviews, including `/ultrareview` and `/code-review ultra`, must also run in Claude Code's terminal.
