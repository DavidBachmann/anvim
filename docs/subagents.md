# Subagents

Claude can start subagents, such as Explore, and several at once. Each running subagent gets a number from 1 to 4 and a color of its own, and anvim names it by its type and that number, such as `Explore 2`. The bullet of its line in the tool pane has that color while it runs.

## Where they are

The footer under the prompt has a dot in each running subagent's color, and their count: `⏺⏺⏺ 3 agents ↓`. In normal mode, `j` or `Down` on the prompt's last line selects the count, and `Enter` then opens the Agent Overview. `k`, `Up` and `Esc` end the selection. Any other key ends it too, and then does its usual work.

In the explorer, an agent's dots in its color show where it works, up to three agents and then `+`. A `⏺` marks the file that the agent reads or writes now, and a `-` marks each other file that it wrote to. A closed folder shows each agent once: a `⏺` when the agent's current file is below it, else a `-`. A subagent's dots go when it ends, and Claude's own dots last until its turn ends.

## Following one

Follow mode follows one agent at a time, at first Claude itself. `<leader>c2` focuses subagent 2, and `<leader>c0` focuses Claude again. The Agent Overview (`<leader>ca`, or `Enter` on the selected agent count) lists Claude and the running subagents, with what each one does, its tool uses and its place, which the preview shows.

While a subagent has focus, the code window goes where that subagent reads and edits, and the other agents' moves leave it alone. The tool pane shows that subagent's own tool calls, and its bar names the agent in its color. The statusline says `◉ following Explore 2` in the agent's color, and the agent's dot in the footer is `◉`.

Claude Code sends a subagent's edits whole, not as they are generated. So while you follow a subagent, anvim types its edits into the code window at a steady pace, in 2 s at most, before the file changes. The other agents never wait for that. When the subagent ends, focus goes back to Claude, the transcript says so, and the tool pane shows Claude's calls again. A permission request from a subagent names it in its color, such as `Edit file · Explore 2 (Find x)`.

## Background agents

A background subagent keeps working after Claude's turn ends. `Ctrl-B` in the prompt, in insert mode, moves the running foreground agents to the background. A background agent's line in the tool pane says `Backgrounded agent`, lists its newest tool calls, and keeps its color and its number until it ends. Then its line shows its totals, and a row at the end of the transcript says `Agent "Find x" finished`, with its summary. When Claude is idle, it replies to each end in a turn of its own, as in Claude Code.

With the tool pane hidden (`<leader>us`), the subagents' lines show in the transcript, as in Claude Code, and the line of the subagent that has focus ends in `◉ focused`.

## New agents

Claude Code gives each turn the agents that it started with. Between turns, it rereads only the agent folders that existed when the session started. When Claude writes or edits an agent file in the project's `.claude/agents/` or in the login's `agents/` folder, anvim reloads the agents at once, also from a new folder. anvim then tells Claude that the agent works from the next turn on, so Claude ends its turn instead of using another agent. For an agent file that something else writes, `/reload-plugins` reloads the agents.
