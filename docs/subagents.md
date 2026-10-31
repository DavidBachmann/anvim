# Subagents

Claude can delegate work to several subagents at once. anvim has four numbered, colored display slots for running agents, for example `Explore 2`. If more than four agents run at once, an agent without a slot receives one when a slot becomes free.

Each Agent call gives a short task, such as `Verify statusline slice`. anvim shows it after the agent's name in the Agent Overview, the statusline, the footer's follow hint and the notice when the agent ends.

<a id="where-they-are"></a>
<a id="following-one"></a>

## Find and follow an agent

While agents are running, press `Ctrl-F` in normal mode to cycle through them and back to Claude. The code window and tool pane follow the selected agent. With no agent running, `Ctrl-F` keeps its usual job.

The prompt footer shows colored dots and the number of running agents. In prompt normal mode, press `j` or `Down` on the last line to select the count. `Enter` opens the Agent Overview; `f` also cycles through agents and back to Claude. `k`, `Up` or `Esc` clears the selection.

Alternatively, `<leader>ca` opens the Overview, `<leader>c1` through `<leader>c4` focus an agent directly, and `<leader>c0` returns to Claude. The Overview lists each agent's task, tool use, location and estimated context use, with a preview of its location. Its list expands to fit, up to half the window.

When an agent is focused, the code window follows its reads and edits, the tool pane shows its calls, and the statusline and footer identify it. Other agents cannot move the view away. Its dots in the explorer mark its current file with `⏺` and other files it wrote with `-`; collapsed folders summarize activity below them. Dots disappear when an agent ends. Claude's own markers last until its turn ends.

Claude Code sends subagent edits whole. When you follow one, anvim animates the edit over at most two seconds and normally waits for the preview before the tool runs. Otherwise it does not wait for that animation. The preview handshake has a timeout; see [architecture](architecture.md#how-an-edit-reaches-disk). When the agent ends, focus returns to Claude and the transcript records the end. A permission request identifies the agent responsible.

<a id="background-agents"></a>

## Background work

`Ctrl-B` in prompt insert mode moves running foreground agents and Bash commands into the background. The agents continue after Claude's turn if needed. Their tool-pane rows show recent calls while running and totals when finished; the transcript records their summaries. When Claude is idle, a background agent's result starts a new Claude turn. With the tool pane hidden (`<leader>us`), agent rows appear in the transcript.

## Codex agents

Start anvim with `--codex` or `ANVIM_CODEX=1`, and Claude gets a `codex` tool that it uses when asked. Codex is off by default, so its startup check runs only when you ask for it. The tool needs the OpenAI Codex CLI on `PATH` with a login (`codex login`). If either is missing, anvim starts without the tool and says why in the transcript. `--no-codex` overrides `ANVIM_CODEX=1` for one run. `:checkhealth anvim` reports availability and the next run's defaults.

A Codex run appears as a background agent such as `Codex 1`, with the same footer, explorer, Overview and follow controls. Its commands and changes appear as Bash, Edit and Write calls. Its changes do not stream; an open file reloads after Codex changes it. The Overview does not show a context percentage because Codex does not provide a window size. The result is returned to Claude and appears in resumed history.

Codex runs `codex exec` in the working directory under its own sandbox. It can write there unless the run is read-only. It does not ask for permissions during the run; anvim can ask before starting a write-capable run, as described in [permissions](permissions.md#the-gaps). `Esc` stops Claude, not Codex; `/clear` stops all Codex agents. Inside cmux, `codex` is cmux's wrapper. anvim sets `CMUX_CODEX_HOOKS_DISABLED=1` for its runs, so the wrapper adds no cmux hooks and no cmux computer-use server.

Claude can give a run its Claude in Chrome tools when the task needs a browser. It passes `mcp_servers: ["claude-in-chrome"]`, and the run gets its own copy of Claude Code's Claude in Chrome server. Codex then drives the same Chrome as Claude, in a separate tab group. The copy uses the browser that is selected for the session in `/chrome`, or the only connected browser. The tool checks this at call time, so Chrome can connect after the session starts. The tool returns an error and starts nothing when Claude in Chrome is not connected or no browser is connected. With several browsers and none selected, the error asks Claude to have you select one with `/chrome`. Codex's browser calls appear in the tool pane as Claude's do, such as `Claude in Chrome[navigate](example.com)`, and a permission request for the run says `with claude-in-chrome`. See [permissions](permissions.md#browser-actions) for what the browser can do.

The model and reasoning effort are chosen independently, using the first value set for each:

1. The tool call, when Claude specifies a value you requested.
2. anvim's saved defaults: `/codex-model <model>` and `/codex-effort <level>`. Use `default` to clear either override. These apply to subsequent runs, including after restart.
3. Codex's own `$CODEX_HOME/config.toml`, or `~/.codex/config.toml` if `CODEX_HOME` is unset. Without an override, anvim passes no flag for that setting.

At startup, anvim asks `codex app-server` for Codex's model list, while it checks the login. With the list, the tool's description names each visible model as `slug (Display Name)`, so Claude can match "6.1 Terra" to `gpt-6.1-terra`, and names the effort levels. The tool checks the model and effort in Claude's call. A model that Codex lacks, or an effort that the run's model does not support, returns an error to Claude and starts nothing. A call may name a hidden model. The tool result names the run's model and effort and where each comes from, or says that Codex's default applies.

Without arguments, `/codex-model` lists the default and Codex's visible models. `/codex-model <name>` refuses a name that is not in the list, but takes a hidden model. `/codex-effort` lists the levels of the model that the next run uses, when the list has that model. `/codex-effort <level>` saves a level without a check. When readable, the pickers show values from Codex's config. anvim passes the model with `-m` and effort as `-c model_reasoning_effort="<level>"`; the Overview shows the values it knows.

If anvim cannot read the list, the transcript says so, and anvim checks no model names or levels. `/codex-model` then lists the default and the last five choices. `/codex-effort` lists low, medium, high, xhigh and max then, and also when the list lacks the next run's model.

<a id="new-agents"></a>

## Adding an agent definition

Claude Code normally discovers agents at session start and rereads existing agent folders between turns. When Claude creates or edits an agent file in the project's `.claude/agents/` or the login's `agents/` directory, anvim reloads definitions, including a newly created folder. It tells Claude the agent is available on the next turn, so Claude ends the current turn first. If another program changes a definition, use `/reload-plugins`.
