# The transcript

<a id="rendering"></a>

The transcript is the conversation above the prompt: your messages, Claude's replies, activity and notices. Prompts, replies, tool calls and notices carry a dim timestamp when there is room, including in agent logs and resumed sessions.

Claude's replies render Markdown, including syntax-highlighted code blocks. Tables show as boxes that fit the transcript's width, with text wrapped inside each cell, and they redraw when the width changes. Prompts and tool input remain literal, so shell syntax is not mistaken for Markdown. Paths under the working directory are shortened for display.

<a id="tool-calls"></a>
<a id="the-todo-list"></a>

## Tool output

By default, the [tool pane](screen.md#the-tool-pane) holds tool calls and the transcript summarizes each run, for example `7 tool calls · 1 failed`. Hide the pane with `<leader>us` to show calls in the transcript instead. Questions and answers always stay in the transcript.

`Ctrl-O` in the prompt toggles verbose mode for the transcript, tool pane and agent logs. It shows full tool input and output in place of abbreviated results; summaries such as `Read 40 lines` remain summaries unless the call failed. The choice lasts until anvim quits.

Claude's [todo list](todos.md) stays below the newest output while it has open items, and the spinner names the item in progress.

<a id="read-mode"></a>

## Scroll, search and copy

The transcript normally takes no focus. Scroll it with the mouse wheel, `PageUp`/`PageDown`, or `Ctrl-U`, `Ctrl-D`, `Ctrl-B` and `Ctrl-F` in prompt normal mode. While agents are running, `Ctrl-F` instead cycles through them and back to Claude. New output follows the bottom unless you have scrolled up; scroll back down or send a prompt to follow it again.

To use Vim motions, search or yank, enter read mode with `<leader>cr` or `:AnvimTranscript`. `q` or `Esc` returns to the prompt; `i`, `a` and the other insert keys return and begin typing. You can also drag across the transcript: releasing the mouse copies the selection without its margin. `<leader>cy` copies Claude's last reply directly.
