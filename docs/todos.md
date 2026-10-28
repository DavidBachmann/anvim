# The todo list

anvim keeps one todo list per project directory. Claude fills it with three tools on anvim's own MCP server: `todo_add`, `todo_update` and `todo_list`. They run without a permission prompt. Each item has an id, a subject, a status (pending, in progress or completed), and optionally a description, an owner and the ids of the items that block it. Ids count up from 1 and are never used twice in a list.

Claude Code's own task tools (TodoWrite and the Task tools) are turned off, so Claude has one list.

## What you see

The list appears in the transcript as `⏺ Todos · 2 of 5 done`, with one row per item: a box, the id and the subject. Items in progress are bold, and completed items are dim and struck through. A row ends with `blocked by #2` while an open item blocks it. The tool calls themselves draw no line, and the tool pane does not count them.

While the list has open items, it stays below the newest output and updates in place. Once every item is done, the list stays where it is. When the list gets open items again, it moves back to the end. The spinner names the item that Claude itself works on, such as `Fixing the parser...`.

## Sessions and agents

The list belongs to the project, not to a session or an account. `/clear` keeps it, and the list moves back to the end of the empty transcript. When a session starts, resumes, clears or compacts, Claude learns the open items, so it can go on with them.

Only the main agent (Claude in the transcript) uses the list. Subagents keep anvim's other tools, but a call to a todo tool returns an error that tells them to report back. Claude marks an item done once it has checked the agent's work.

## Where it lives

The list is a JSON file in anvim's state dir: `~/.local/state/anvim/todos/<dir>-<hash>.json`, where `<dir>` is the project directory's name and `<hash>` comes from its full path. Two anvims in one project share the file. Each change takes a lock, and each anvim shows the other's changes. A replay has no list file and shows only the recorded list.
