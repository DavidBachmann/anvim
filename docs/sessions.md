# Sessions and slash commands

## Resume

Claude Code saves every session, and anvim reads them through the Agent SDK. `anvim -c` goes on with the latest session in the directory, and `anvim --resume <id>` with that one. `--resume` without an id opens the session picker at start. In anvim, `<leader>cs` or `/resume` opens it: each session shows its title or first prompt, when it changed, its size and its branch, with details in the preview.

Choosing one starts Claude again in that session and draws its past in the transcript, as it looked live. A session that Claude Code compacted starts at the compaction, because Claude Code keeps only the summary. Its items show the times that Claude Code saved. A background subagent's end shows as it did live, but past subagents get no numbers, colors or dots.

`/clear` starts a new session and empties the transcript.

## Model and effort

`<leader>cm` or `/model` lists the models that Claude Code offers, and the statusline shows the one you choose. `/model sonnet` switches at once.

`/effort` lists the effort levels of the current model, and `/effort high` sets one at once, for this session only, without a change to your settings. `/effort default` gives the effort that a new session would have: the level in your Claude Code settings for the model, else the model's. The default follows a model switch, and a level that you chose stays, as in Claude Code. `/effort current` asks Claude Code which level applies. The statusline shows the level that the session uses next to the model, as in `Haiku 5.5 · high`, and no level for a model without effort levels.

`/codex-model` and `/codex-effort` set the model and the effort of Codex agents. [Subagents](subagents.md#codex-agents) explains them.

Before the model, a meter shows how full the context window is, as in `▰▰▰▰▰▱▱▱▱▱ 64%`. It changes when a turn ends. The statusline shows the login's email before the meter, so a work login and a personal one differ at a glance. After the email, `[S27%/W80%]` shows how much of the plan's 5-hour session and of its week you have used, as `/usage` does. It changes at start and when a turn ends. A login without plan limits, such as an API key, shows none.

`<leader>cR` or `:AnvimRestart` starts Claude again when it exited or hangs, in the same session, and keeps the model and effort you chose. A restart with the default effort starts as a new session would.

## Accounts

Claude Code keeps one login in each config dir, and `CLAUDE_CONFIG_DIR` picks the dir. An account in anvim is such a dir. The account `default` leaves the variable unset, so Claude Code uses `~/.claude` and the login in `~/.claude.json`. Each `~/.claude-<name>` whose `.claude.json` holds a login is the account `<name>`, such as `personal` for `~/.claude-personal`.

At start, the first of these rules that applies picks the account:

1. `anvim --account personal` (or `ANVIM_ACCOUNT=personal`). An unknown name gets a warning, and a picker asks.
2. `CLAUDE_CONFIG_DIR` in the environment, as in `CLAUDE_CONFIG_DIR=~/.claude-personal anvim`.
3. The account that anvim remembers for the directory, if it still has a login. anvim remembers the account of each start.
4. With two or more accounts, a picker asks before Claude starts. When you close it without a choice, Claude does not start, and `/account` starts it.
5. The only account, or else `default`.

`/account` or `:AnvimAccount` opens the picker. Each row shows the name, the email and the organization, and `⏺` marks the current account. `/account personal` switches at once. A switch restarts Claude. When both accounts read the same sessions, because one links the other's `projects` dir, Claude goes on in the same session, if it has a turn. Otherwise it starts a new session, as after `/clear`. While Claude or an agent works, anvim does not switch.

`/account add work2`, or the picker's last row, adds an account. anvim asks if the new account shares settings, instructions, skills and sessions with `~/.claude`. Sharing links these from `~/.claude` into `~/.claude-work2`, but never over a file that is already there. Then Claude Code's own login runs in a window, with the browser for the sign-in. The window opens in normal mode: press `i` to type a code that the login asks for, and `q` to close it and stop the login. When the login succeeds, the window closes, and `/account work2` switches to the new account. When it fails, the window stays open, so you can read why.

The Settings window's Status tab shows the account, and `:checkhealth anvim` lists the accounts and says why this start uses its account.

## The Settings window

`/status`, `/usage`, `/context` and `/mcp` open a window like Claude Code's Settings dialog, and `Tab` moves between its tabs. `q` or `Esc` closes it. Unlike the text that Claude Code's `/usage`, `/context` and `/mcp` print, the window adds nothing to Claude's context.

- Status shows the Claude Code version, the account, the config dir, how Claude Code logs in, the organization, the email and the MCP servers.
- Usage shows the session's cost and tokens, your plan's limits as bars with their reset times, and what used the plan in the last 24 hours and 7 days. `/cost` and `/stats` open Usage too.
- Context shows Claude Code's grid of the context window, with what fills it: the MCP tools by server, the agents, the memory files and the skills.
- MCP lists the MCP servers with their status. On a server's line, `Enter` shows what the server runs and its tools, `r` reconnects it, and `t` turns it on or off. anvim's own server always runs. A server that needs a sign-in needs Claude Code's `/mcp` in a terminal, because the Agent SDK cannot sign in. `/mcp reconnect <server>` and the other forms with arguments still run in Claude Code.
- Chrome is Claude Code's Claude in Chrome dialog, see below.

## Claude in Chrome

With Claude in Chrome, Claude uses your Chrome through the Claude extension: it opens pages, clicks, fills forms, reads the console and takes screenshots. It needs a claude.ai login. `anvim --chrome` turns it on and `--no-chrome` turns it off, as `claude --chrome` does. Without them, Claude Code's "Enabled by default" setting decides.

`/chrome` opens the Settings window's Chrome tab. It shows the status, the extension and the browser in use. `Enter` runs the option under the cursor: install the extension, select the browser, manage the extension's site permissions, reconnect it, or switch "Enabled by default". That setting holds for the next sessions, in anvim and in Claude Code's terminal. When this session runs without Claude in Chrome, "Reconnect extension" restarts Claude in the same session with it on.

The tool calls read as in Claude Code, such as `Claude in Chrome[navigate](example.com)`. The extension's site permissions decide where Claude may browse, click and type. A session that starts in bypass mode, anvim's default, tells the extension to skip these checks, as `claude --dangerously-skip-permissions` does. Claude then acts on any site without asking, and the tab says so. Start anvim with `--mode default` to keep the checks.

## Other slash commands

Other slash commands run in Claude Code, and their output shows under them, such as `/skill-doctor`. The completion menu lists the commands that work here: Claude Code's own, which it lists for the Agent SDK, and every command of yours, your projects, plugins and skills. It leaves out the few that work only in Claude Code's terminal, such as `/color`, `/focus` and `/doctor`. Typed anyway, they get a notice and go nowhere. anvim also starts no paid cloud review, so `/ultrareview` and `/code-review ultra` work only in Claude Code. Claude Code answers a terminal-only command that it does not list, such as `/help`, with "isn't available in this environment".

As in Claude Code, `Enter` on a slash command in the completion menu completes it and sends it. A command that needs an argument, such as `/batch <instruction>`, is only completed, so you can type the argument.
