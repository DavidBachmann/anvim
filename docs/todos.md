# The todo list

anvim keeps one todo list per project directory. Claude fills it with three tools on anvim's own MCP server: `todo_add`, `todo_update` and `todo_list`. They run without a permission prompt. Each item has an id, a subject, a status (pending, in progress or completed), and optionally a description, an owner and the ids of the items that block it. Ids count up from 1 and are never used twice in a list.

Claude Code's own task tools (TodoWrite and the Task tools) are turned off, so Claude has one list.

## What you see

The list has one row per item: a box, the id and the subject. Items in progress are bold, and completed items are dim and struck through. A row ends with `blocked by #2` while an open item blocks it. The tool calls themselves draw no line, and the tool pane does not count them. The spinner names the item that Claude itself works on, such as `Fixing the parser...`.

The todo window sits on top of the Claude column, above the transcript, while the list has items. Its bar reads `Todos · 2 of 5 done`, and a rule separates it from the transcript. Long subjects wrap. In a long list, the view starts at the first open item, so done items scroll out of sight. The window takes no focus; use the mouse wheel to scroll it.

The window takes 30% of the column's rows (`layout.todo_height`). It never leaves the transcript fewer than 5 rows (`layout.transcript_min`) next to the prompt at its largest. On a terminal too short for that, the window closes until the room comes back. Drag the rule under it to change its share for this run.

`<leader>ut` turns the window off and on, and the choice persists across starts. Without the window, the list shows in the transcript as `⏺ Todos · 2 of 5 done` with the same rows. While the list has open items, it stays below the newest output and updates in place. Once every item is done, the list stays where it is. When the list gets open items again, it moves back to the end. A list with open items shows in one place only. A finished list that stays in the transcript is history, as the output around it is.

## Sessions and agents

The list belongs to the project, not to a session or an account. `/clear` keeps it, and the list moves back to the end of the empty transcript. When a session starts, resumes, clears or compacts, Claude learns the open items, so it can go on with them.

`/reset` clears the conversation and deletes the list, so the ids start again at 1. The deleted list becomes the previous list. anvim keeps one previous list, and the next `/reset` replaces it. A `/reset` of an empty list keeps the previous list. `/undo-reset` swaps the list and the previous list, so a second `/undo-reset` swaps them back. It does not clear the conversation.

Only the main agent (Claude in the transcript) uses the list. Subagents keep anvim's other tools, but a call to a todo tool returns an error that tells them to report back. Claude marks an item done once it has checked the agent's work.

## Where it lives

The list is a JSON file in anvim's state dir: `~/.local/state/anvim/todos/<dir>-<hash>.json`, where `<dir>` is the project directory's name and `<hash>` comes from its full path. The previous list is `<dir>-<hash>.prev.json` next to it. Two anvims in one project share the file. Each change takes a lock, and each anvim shows the other's changes. A replay has no list file and shows only the recorded list.
