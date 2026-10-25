# The transcript

The transcript fills the Claude column above the prompt. It looks like Claude Code: your prompts after `❯`, Claude's replies, and a spinner while Claude works.

## Rendering

Claude's replies render their markdown, as in Claude Code: bold, inline code and links show without their markers, and code blocks have syntax colors. Tool lines, their results and your prompts show as they are, so a command such as `grep '**' *.lua` keeps its stars. Paths under the working directory show short: `Bash(find . -name '*.lua')`.

Your prompts, each block of Claude's text, tool calls and notices show the time they arrived, dimmed at the right edge. An agent's log shows them too. A time shows only where its row has room for all of it.

## Tool calls

With the tool pane on, the transcript keeps one dim line for each run of tool calls, such as `⎿  7 tool calls · 1 failed`, and the pane under the code window lists the calls. With the pane off (`<leader>us`), the calls show in the transcript, as in Claude Code. Claude's questions and your answers always show in the transcript. See [screen.md](screen.md).

In the tool pane, a subagent's line shows its last three tool calls while it works, and then a summary such as `Done (12 tool uses · 24.1k tokens · 1m 2s)`. A compaction shows as a notice with the tokens before and after.

## The todo list

Claude's todo list stays at the end of the transcript, under the newest output, while it has open items. Claude Code keeps it with TodoWrite, or with TaskCreate and TaskUpdate. For its newest models, it offers these tools only when `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set. The item in progress is bold, and the spinner names it. Once every item is done, the list stays in the transcript where it was.

## Read mode

The transcript takes no focus. To yank or search in it, enter read mode with `<leader>cr` or `:AnvimTranscript`. `q` or `Esc` goes back to the prompt, and `i`, `a` and the other insert keys go back and type. A mouse drag across the transcript selects text too. `<leader>cy` yanks Claude's last reply to the clipboard without read mode.
