# The transcript

<a id="rendering"></a>

The transcript is the conversation above the prompt: your messages, Claude's replies, activity and notices. Prompts, replies, tool calls and notices carry a dim timestamp when there is room, including in agent logs and resumed sessions.

Claude's replies render Markdown, including syntax-highlighted code blocks. Prompts and tool input remain literal, so shell syntax is not mistaken for Markdown. Paths under the working directory are shortened for display.

<a id="tool-calls"></a>
<a id="the-todo-list"></a>

## Tool output

By default, the [tool pane](screen.md#the-tool-pane) holds tool calls and the transcript summarizes each run, for example `7 tool calls · 1 failed`. Hide the pane with `<leader>us` to show calls in the transcript instead. Questions and answers always stay in the transcript.

`Ctrl-O` in the prompt toggles verbose mode for the transcript, tool pane and agent logs. It shows full tool input and output in place of abbreviated results; summaries such as `Read 40 lines` remain summaries unless the call failed. The choice lasts until anvim quits.

An open todo list stays below the newest output, with the active item in bold and named by the spinner. Completed lists stay where they were. Claude Code supplies TodoWrite or TaskCreate/TaskUpdate; for its newest models these tools require `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`.

<a id="read-mode"></a>

## Scroll, search and copy

The transcript normally takes no focus. Scroll it with the mouse wheel, `PageUp`/`PageDown`, or `Ctrl-U`, `Ctrl-D`, `Ctrl-B` and `Ctrl-F` in prompt normal mode. New output follows the bottom unless you have scrolled up; scroll back down or send a prompt to follow it again.

To use Vim motions, search or yank, enter read mode with `<leader>cr` or `:AnvimTranscript`. `q` or `Esc` returns to the prompt; `i`, `a` and the other insert keys return and begin typing. You can also drag across the transcript: releasing the mouse copies the selection without its margin. `<leader>cy` copies Claude's last reply directly.
