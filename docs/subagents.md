# Subagents

Claude can start subagents, such as Explore, and several at once. Each running subagent gets a number from 1 to 4 and a color of its own, and anvim names it by its type and that number, such as `Explore 2`. The bullet of its line in the tool pane has that color while it runs.

## Where they are

The footer under the prompt has a dot in each running subagent's color, and their count: `⏺⏺⏺ 3 agents ↓`. In normal mode, `j` or `Down` on the prompt's last line selects the count, and `Enter` then opens the Agent Overview. `k`, `Up` and `Esc` end the selection. Any other key ends it too, and then does its usual work.

In the explorer, an agent's dots in its color show where it works, up to three agents and then `+`. A `⏺` marks the file that the agent reads or writes now, and a `-` marks each other file that it wrote to. A closed folder shows each agent once: a `⏺` when the agent's current file is below it, else a `-`. A subagent's dots go when it ends, and Claude's own dots last until its turn ends.

## Following one

Follow mode follows one agent at a time, at first Claude itself. `<leader>c2` focuses subagent 2, and `<leader>c0` focuses Claude again. The Agent Overview (`<leader>ca`, or `Enter` on the selected agent count) lists Claude and the running subagents, with what each one does, its tool uses and its place, which the preview shows. Each row also says how full that agent's context window is, such as `23%`. A subagent's percent comes from its last response. On a wide screen, the list of agents is as wide as its longest row, up to half the Overview, and it widens when a longer row comes.

While a subagent has focus, the code window goes where that subagent reads and edits, and the other agents' moves leave it alone. The tool pane shows that subagent's own tool calls, and its bar names the agent in its color. The statusline says `◉ following Explore 2` in the agent's color, and the agent's dot in the footer is `◉`.

Claude Code sends a subagent's edits whole, not as they are generated. So while you follow a subagent, anvim types its edits into the code window at a steady pace, in 2 s at most, before the file changes. The other agents never wait for that. When the subagent ends, focus goes back to Claude, the transcript says so, and the tool pane shows Claude's calls again. A permission request from a subagent names it in its color, such as `Edit file · Explore 2 (Find x)`.

## Background agents

A background subagent keeps working after Claude's turn ends. `Ctrl-B` in the prompt, in insert mode, moves the running foreground agents to the background. A background agent's line in the tool pane says `Backgrounded agent`, lists its newest tool calls, and keeps its color and its number until it ends. Then its line shows its totals, and a row at the end of the transcript says `Agent "Find x" finished`, with its summary. When Claude is idle, it replies to each end in a turn of its own, as in Claude Code.

With the tool pane hidden (`<leader>us`), the subagents' lines show in the transcript, as in Claude Code, and the line of the subagent that has focus ends in `◉ focused`.

## Codex agents

When OpenAI's Codex CLI is on your `PATH` and logged in (`codex login`), Claude has a `codex` tool that hands a task to a Codex agent. `--no-codex` or `ANVIM_CODEX=0` takes the tool away, and `:checkhealth anvim` says whether it is there and why. Claude uses it when you ask for Codex or for the opinion of another model. A Codex agent shows as a background subagent named `Codex 1`: its number and color, its dots in the footer and the explorer, its row in the Agent Overview, its line in the tool pane, and follow mode with `<leader>c1`. Its commands and its file changes show as `Bash`, `Edit` and `Write` calls, and its replies as its text. When it ends, Claude gets its result in a turn of its own, as for a background agent, and a resumed session shows that end too.

Codex runs `codex exec` in the working directory, in its own sandbox. It can write files there, unless Claude asks for a read-only run. A Codex agent has less than a Claude subagent. Its edits do not stream: the file reloads after Codex changes it. Its Overview row has no context percent, because Codex does not say how big its window is. It never asks for permission, because Codex's sandbox decides what it may do. `Esc` stops Claude, not a Codex agent, and `/clear` stops every Codex agent.

A Codex agent's model and reasoning effort come from the first of three places that sets them. Each one counts on its own, so a run can take its model from one place and its effort from another:

1. The call. Claude sets a model or an effort only when you name one, as in "ask Codex with low effort".
2. anvim's defaults. `/codex-model gpt-5.1-codex` and `/codex-effort low` set them at once, and they apply from the next Codex run on, also after a restart. `/codex-model default` and `/codex-effort default` clear them. `/codex-model` alone lists default and the last five models that you set. `/codex-effort` alone lists default, low, medium, high, xhigh and max. A typed level goes to Codex as it is, so a newer one works too.
3. Codex's own `config.toml`. anvim passes no flag, and Codex decides.

anvim passes a model as `-m <model>` and an effort as `-c model_reasoning_effort="<level>"`. In the pickers, default names what the `model` and `model_reasoning_effort` keys of `$CODEX_HOME/config.toml` (or `~/.codex/config.toml`) set, such as `default (Codex's config: xhigh)`, when anvim can read them. The Agent Overview shows what each Codex agent runs with, in its row and in its preview's title, such as `gpt-6.1-sol · low`. A value that neither the call nor anvim set comes from Codex's config, and without one the Overview shows nothing. `:checkhealth anvim` shows the defaults of the next run.

## New agents

Claude Code gives each turn the agents that it started with. Between turns, it rereads only the agent folders that existed when the session started. When Claude writes or edits an agent file in the project's `.claude/agents/` or in the login's `agents/` folder, anvim reloads the agents at once, also from a new folder. anvim then tells Claude that the agent works from the next turn on, so Claude ends its turn instead of using another agent. For an agent file that something else writes, `/reload-plugins` reloads the agents.
