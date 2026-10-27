# The prompt

The prompt sits beneath the transcript. It starts in normal mode: press `i` to write, `Enter` to send, and `Shift-Enter` or `Alt-Enter` for a new line. Moving focus to the prompt does not start insert mode for you.

## Pointing at code

Claude does not automatically receive the file or selection you are looking at. Add a reference when you want to point something out:

- In a file, select lines and press `c` to insert a reference and continue typing. In normal mode, `c{motion}` references the lines covered by a motion (`cip`, for example), and `cc` references the current line. A count extends `cc` to more lines.
- `<leader>cb` references the selection in visual mode or the whole file in normal mode, then moves to the prompt without entering insert mode.
- In the explorer, `@` references a whole file. In the prompt, type `@` for file and directory completion.

A reference looks like `@src/app.lua#L12-30`: line numbers are 1-based and inclusive. You can include several. Claude Code reads those lines into the prompt. In addition to your message, anvim supplies an [appended system instruction](architecture.md#from-a-prompt-to-the-screen) describing its viewer and editor tools.

`<leader>ct` opens a searchable trail of files and ranges Claude read, edited, wrote or showed you, as well as your references. `Enter` opens the selected place. For slash commands, type `/` at the start of the prompt; `Ctrl-Space` also completes words from open files.

<a id="the-compose-window"></a>

## Writing a longer prompt

`Ctrl-G` opens the compose window. `Enter` adds a line there, and `@` and `/` completion still work. `Ctrl-G`, `:wq` or `ZZ` returns the text to the prompt and closes the window; `:w` copies it back while keeping the window open; `:q!` discards changes. Leaving the window also keeps the text. Follow mode continues while you compose.

## Images

Paste an image or drop an image file onto the terminal. The prompt shows a chip such as `[Image #1]`, and anvim sends the image with the prompt. Supported files are PNG, JPEG, GIF and WebP up to 3.7 MB. A notice identifies any file that could not be sent.

<a id="past-prompts"></a>
<a id="a-prompt-sent-while-claude-works"></a>

## History and queued prompts

anvim saves the last 200 prompts per directory in its state directory. In insert mode, `Up` on the first line and `Down` on the last line move through history and back to your draft. In normal mode use `Ctrl-P` and `Ctrl-N`. When completion is open, arrow keys navigate the menu instead.

You can send a prompt while Claude is working. It appears below the prompt as `queued` and enters the transcript when Claude Code takes it, after a tool result or at the end of the turn. To revise it, press `Up` on the first prompt line (or `k` in normal mode). Queued text returns ahead of your draft and is removed from the queue; send it again when ready. If Claude takes it before cancellation, a notice tells you. If Claude stops before taking it, `Up` retrieves it.

A foreground agent's tool call stays open until the agent finishes, so a queued prompt may wait. `Ctrl-B` in insert mode moves running foreground agents and Bash commands to the background, allowing the main turn to continue. Stopping Claude also stops its foreground agents. See [subagents](subagents.md).

## Stopping Claude

In the prompt's normal mode, press `Esc`, pause at least 0.4 seconds, then press `Esc` again within three seconds. The first press arms the action and displays a red hint. A rapid burst of Esc presses does not stop Claude: each early press restarts the pause. Another key, leaving the prompt, a change in activity or request, or the timeout disarms it. `Ctrl-C` or `:AnvimStop` stops immediately.

The same two-press gesture answers No to a [permission request](permissions.md#answering-a-request), without confusing a routine escape from insert mode with a rejection.

## Notifications

When the terminal is out of focus and Claude finishes or needs an answer, anvim sends a desktop notification. It uses `cmux notify` inside cmux and OSC 9 elsewhere. It does not notify while the terminal has focus.
