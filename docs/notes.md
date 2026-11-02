# The .anvim folder

Each project has a private folder, `.anvim/`, for the notes that you and Claude keep about it. Git never sees it. At each start, anvim adds `.anvim/` to the repo's local exclude file (`.git/info/exclude`), which git does not share as it shares `.gitignore`. The explorer hides the folder with the other ignored files; press `I` to show it.

```text
.anvim/
  README.md     the standing context: the project in a paragraph, the decisions in force, where things live
  diary/        one markdown file per day, such as 2026-11-01.md
  docs/         internal reference docs: plans, specs, research, reviews, handovers, drafts for other people
  scratch/      scripts, test kits, outputs, logs and data worth keeping
  todos/        the todo lists, one per chain of sessions
```

anvim creates the folder for the [todo lists](todos.md). Claude creates the rest when it has something to record.

## How Claude uses it

[The system prompt](../sidecar/src/systemprompt.ts) explains the folder. With your first prompt, anvim also tells Claude today's date, today's diary file and whether it exists yet, the newest earlier entry, and whether the README exists. Claude hears this again after `/clear`, after a compaction, and when the date changes during a session.

Claude reads the README before it works on the project, and updates it when a standing fact changes. As it works, it writes in today's diary file what happened, what you decided (in your words) and what is open. Throwaway files go to the sandbox's temp dir instead of `scratch/`.

The notes stay private. Claude never names `.anvim/` or its files in code, code comments, tests, committed docs, commits, or PR and issue text. When a fact from the notes belongs in the repo, Claude writes it there in full.

Claude Code's auto memory has a different job. It holds rules about how to work with you, and it loads into every session. The notes hold the story and the state of the work, and Claude reads them when it needs them.

## Guards

The diary holds only day files. A Write or Edit in `.anvim/diary/` whose name is not `YYYY-MM-DD.md` goes back to Claude, with a hint to use `scratch/` or `docs/`. A file that a Bash command writes gets past this check.

Only the main agent writes the diary. Each subagent learns the rules for the notes when it starts, and a subagent's edit in the diary goes back to it with a hint to report instead.

## Amnesia

An [amnesia session](sessions.md#fresh-eyes) cannot read `.anvim/`. A Read deny rule stops the Read tool and the Bash commands that name the folder. The sandbox stops the other Bash commands, such as a grep over the project. The system prompt leaves the notes out, and the todo list is a temporary one.

Without the sandbox (`--no-sandbox`), only the deny rule applies. A Bash command that reads the folder without naming it can then still see the notes.
