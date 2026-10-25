# The prompt

The prompt is at the bottom of the Claude column. anvim starts with the cursor there, in normal mode. Press `i` to type, and `Enter` to send. `Shift-Enter` or `Alt-Enter` adds a line.

## Pointing at code

A prompt carries only what you write. anvim adds no hidden context, such as the file in the code window or your selection. To show Claude code, put a reference in the prompt.

References are text in the prompt, in the form `@path#L12-30`, and you can write several. Claude Code reads the lines of each reference into the prompt, so Claude needs no tool call to see them.

In a file buffer, `<leader>cb` puts a reference to the selection in the prompt, in any visual mode, or to the whole file in normal mode. The cursor then goes to the prompt, in normal mode. `c` puts one in the prompt and goes on typing after it: `c` in visual mode for the selection, `c{motion}` for the lines of a motion such as `cip` or `cj`, and `cc` for the current line or, with a count, more lines. Read-only buffers leave `c` free, so read it as "change this, Claude". `@` in the explorer references whole files and leaves the cursor after them, in normal mode.

In the prompt, `@` completes files and directories, and `/` at the start completes slash commands. `Ctrl-Space` also completes words from the open files.

`<leader>ct` opens Claude's trail: every file and range that Claude read, edited, wrote or showed you, and your own references, newest first, with a preview. `Enter` opens the place in the code window.

## The compose window

For a long prompt, `Ctrl-G` in the prompt opens it in a large window in the middle of the screen, as Claude Code's `Ctrl-G` opens it in your editor. There `Enter` adds a line, and `@` and `/` complete as in the prompt. `Ctrl-G` again, `:wq` or `ZZ` puts the text back in the prompt, at the same place and in the same mode: after `Ctrl-G` while typing you go on typing, and after `:wq` you are in normal mode. `:w` puts it there and keeps the window open, and `:q!` drops your changes. Leaving the window keeps the text too. Follow mode goes on while you write.

## Images

Paste an image in the prompt, or drop an image file on the terminal, and the prompt shows a chip such as `[Image #1]`, as in Claude Code. The terminal pastes the image as the path of its file, and anvim sends the image itself to Claude with the prompt. Claude gets PNG, JPEG, GIF and WebP files up to 3.7 MB, and a notice names a file that it did not get.

## Past prompts

Your prompts are saved per directory, the last 200, in anvim's state dir. `Up` on the first line of the prompt goes back through them, and `Down` on the last line comes forward again, back to what you were typing. While the completion menu is open, `Up` and `Down` move in the menu instead. In normal mode, `Ctrl-P` and `Ctrl-N` do the same.

## A prompt sent while Claude works

A prompt that you send while Claude works waits under the prompt box, dimmed and marked `queued`, as in Claude Code. It joins the transcript when Claude Code takes it: after Claude's next tool call, or when the turn ends. So a reply that streams in is never split by your prompt. If Claude stops before it takes a queued prompt, a notice says so, and `Up` in the prompt brings the text back.

To change a queued prompt, press `Up` on the first line of the prompt, as in Claude Code. The last queued prompt says `↑ to edit`. The queued prompts come back into the prompt, ahead of what you typed, and Claude Code drops them from its queue. Send them again when they are right. If Claude Code takes a prompt before it can drop it, the prompt joins the transcript, and a notice says so.

A foreground agent's tool call ends only when the agent ends, so a queued prompt waits for it. `Ctrl-B` in insert mode moves the running foreground agents and Bash commands to the background, as in Claude Code. They work on, and Claude's turn goes on and takes the prompt. While a foreground agent runs, the activity line says `ctrl+b to background`. Stopping Claude stops its foreground agents too.

## Stopping Claude

`Esc` in normal mode in the prompt stops Claude while Claude works, or answers No to a request. It acts only when you press it twice. The first press only arms it. The line above the prompt then says in red what the next press does, such as "esc again to stop Claude". Press `Esc` again after a pause of at least 0.4 s and within 3 s. A press within the pause does nothing and starts the pause again, so a burst of `Esc` presses never stops Claude. A busy change, a new or changed request, any other key, leaving the prompt and the end of the 3 s limit take the red text away. The next `Esc` then starts over. `Ctrl-C` stops Claude at once.

## Notifications

When Claude is done, or needs your answer, while the terminal does not have focus, anvim posts a desktop notification. Inside cmux, it uses `cmux notify` for its own pane. Elsewhere it writes OSC 9, which many terminals show as a notification. It never notifies while you look at it.
