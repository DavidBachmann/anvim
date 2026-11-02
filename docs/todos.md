# The todo list

anvim keeps one todo list per session. Claude fills it with three tools on anvim's own MCP server: `todo_add`, `todo_update` and `todo_list`. They run without a permission prompt. Claude adds items on its own for work of 3 or more steps, or when you give several tasks. It skips the list for a small task or a question. Each item has an id, a subject, a status (pending, in progress or completed), and optionally a description, an owner and the ids of the items that block it. Ids count up from 1 and are never used twice in a list.

Claude Code's own task tools (TodoWrite and the Task tools) are turned off, so Claude has one list.

## What you see

The list has one row per item: a box, the id and the subject. Items in progress are bold, and completed items are dim and struck through. A row ends with `blocked by #2` while an open item blocks it. The tool calls themselves draw no line, and the tool pane does not count them. The spinner names the item that Claude itself works on, such as `Fixing the parser...`.

The todo window sits on top of the Claude column, above the transcript, while the list has items. Its bar reads `Todos · 2 of 5 done`, and a rule separates it from the transcript. Long subjects wrap. In a long list, the view starts at the first open item, so done items scroll out of sight. The window takes no focus; use the mouse wheel to scroll it.

The window takes the rows that the list needs, up to 30% of the column's rows (`layout.todo_height`). It never leaves the transcript fewer than 5 rows (`layout.transcript_min`) next to the prompt at its largest. On a terminal too short for that, the window closes until the room comes back. Drag the rule under it to change its share for this run.

`<leader>ut` turns the window off and on, and the choice persists across starts. Without the window, the list shows in the transcript as `⏺ Todos · 2 of 5 done` with the same rows. While the list has open items, it stays below the newest output and updates in place. Once every item is done, the list stays where it is. When the list gets open items again, it moves back to the end. A list with open items shows in one place only. A finished list that stays in the transcript is history, as the output around it is.

## Sessions and agents

The list belongs to a session, and to the sessions that come from it. `/clear` starts a new session that keeps the list, and the list moves back to the end of the empty transcript. A compaction, a rewind and a fork keep it too. A resume brings the session's list back, and so does `anvim -c`. A restart, such as `<leader>cR` or an account switch, keeps the list. A new session starts with an empty list, so two anvims in one project, such as one on the app and one on the server, each have their own list. When a session resumes, clears or compacts, Claude learns the open items, so it can go on with them.

`/reset` clears the conversation and starts a new, empty list, so the ids start again at 1. The old session keeps the old list, which becomes the previous list of the new one. A `/reset` of an empty list keeps the previous list. `/undo-reset` swaps the list and the previous list, so a second `/undo-reset` swaps them back. It does not clear the conversation.

The [resume picker](sessions.md#resume) shows the number of open items in each session's list, such as `3 todos`.

Only the main agent (Claude in the transcript) uses the list. Subagents keep anvim's other tools, but a call to a todo tool returns an error that tells them to report back. Claude marks an item done once it has checked the agent's work.

Claude can give an item to an agent. It names the Agent call and sets that name as the item's owner. For a Codex agent, the owner is the agent id that the codex tool returns. The row shows the owner after the subject, as in `#2 Fix the parser · parser-fix`. While the agent runs, the owner has the agent's color, as in the footer and the tree. The owner is dim once the agent ends, and on a completed row. An owner that anvim does not know, such as after a restart, is plain.

## Where it lives

The lists live in `todos/` in the project's [`.anvim/` folder](notes.md), which git excludes, so they move with the project. Each list is a JSON file with its own id, and it names its previous list. `sessions.json` maps each session to its list. A list file appears with the list's first item, at a `/reset` of a list with items, and when an older list moves in. Two anvims that resume the same session share its list. Each change takes a lock, and each anvim shows the other's changes. A replay has no list file and shows only the recorded list. An [amnesia session](sessions.md#fresh-eyes) keeps its lists in a temporary dir, so it neither sees nor changes the project's lists, and the lists go when anvim quits.

An older anvim kept one list per project, in `.anvim/todos.json`, or before that in `~/.local/state/anvim/todos/`. The first anvim to start after the update takes that list as its own, with its previous list. A new session takes it in at its first prompt, so an anvim that quits before then leaves it in place. Other sessions start empty.
