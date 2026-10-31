# Screenshots

These shots come from one short session. Claude reads anvim's own source, edits a function and points at the change. Then it starts five background agents: four Claude Haiku agents and one GPT-6.1 Terra agent through Codex. At the end, Claude reverts every edit.

## Following Claude

![The Ctrl-G prompt editor with a six-step request](01-prompt-editor.png)

`Ctrl-G` opens a larger editor for long prompts.

![The code window shows a grep hit in trail.lua while the tool pane lists the calls](02-follow-reads.png)

Claude greps and reads the source. The code window follows each read and grep hit, the todo list sits on top, and the tool pane lists the calls.

![The old M.flash is struck through while the new text streams in](03-edit-streams.png)

Claude rewrites `M.flash`. The old lines are struck through while the new ones stream in.

![The new runs() helper fills in under the struck-through lines](04-edit-lands.png)

The new code fills in. Claude Code writes the file to disk once the preview has caught up.

![A show_user note above the new code](05-show-user-note.png)

Claude ends with `show_user`, so a note appears above the new code.

## Background agents

![Five agents in the tool pane, with their dots in the footer](06-five-agents.png)

Five agents start. The tool pane lists them, and the footer shows a dot in each agent's color.

![anvim follows Agent 1 while it edits trail.lua](07-follow-agent.png)

anvim follows Agent 1. The code window and the tool pane show its edits to `trail.lua`.

![The Agent Overview with five agents and Agent 2's prompt and edits](08-agent-overview.png)

The Agent Overview (`<leader>ca`) lists each agent with its model, task and context use. The right side shows the selected agent's prompt and tool calls.

![Agent 4 adds type annotations to prefs.lua](09-agent-edit.png)

Agent 4 adds type annotations to `prefs.lua` while you follow it.

![Claude reports that git checkout reverted the six changed files](10-reverted.png)

Claude reverts the demo edits with `git checkout` and empties the todo list.

## Menus and windows

![The which-key menu for the leader-c keys](11-which-key.png)

The `<leader>c` menu holds the Claude keys: follow an agent, open the Agent Overview, choose the model and more.

![The Processes window with anvim's own processes on top](12-processes.png)

The Processes window (`<leader>cp`) lists anvim's own processes first, then the busiest processes on the machine.
