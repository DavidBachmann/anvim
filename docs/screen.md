# The screen

The screen has three columns: the explorer, the code and Claude. The Claude column has the transcript above the prompt. Under the code window, the tool pane lists Claude's tool calls.

## The explorer

`<leader>e` hides the explorer, and so do `q` and `Esc` in its list. The code window then takes its columns. `<leader>e` again opens the explorer with the cursor in its list. The explorer shows again at the next start.

The explorer is 30 columns wide. While it has focus, it widens over the code window to fit its names, and the code window stays where it is. `<leader>ue` turns off this auto-minimize: the explorer then always fits its names, up to 40% of the screen, and the code window gives it the columns. `<leader>uH` swaps the sides, so Claude is on the left and the explorer on the right. anvim remembers both choices for the next start.

## Follow mode

anvim starts with the cursor in the prompt at the bottom right, in normal mode, so your first keys can move around. Press `i` to type. A rule above the prompt and a rule below it frame your text, also when it has several lines.

While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Claude often reads with Bash, so `cat`, `head`, `tail`, `sed -n` and `nl` open their files too, and a `grep -n` opens at its first hit.

Move the cursor anywhere else to take control and review code. The statusline then shows where Claude is, such as `⏺ Claude at stream.lua:40 +2`, and `<leader>j` jumps there. In the prompt it says `◉ following`. On a narrow screen, the statusline drops the jump hint, the effort, the model and the context meter, and then the words, as in `⏺ stream.lua:40 +2`. After that, the file goes, because the bar above the code names it, and the branch gets shorter.

Follow mode is a mode of its own, next to Vim's normal, insert and visual mode. The statusline starts with `anvim`, and the mode block after it reads `FOLLOW` in Claude's orange, also while you type in the prompt. In follow mode the code window shows absolute line numbers. In review mode the block shows Vim's mode, and the code window has the line numbers that your config sets. A `:set number` there lasts until you go back to the prompt. In both modes the numbers have room for at least three digits, and the text stays in place when the mode changes. While you follow, the gutter keeps its width, so the text that Claude writes never moves right when a file grows. A line number that no longer fits then shows as a blank until you leave follow mode. A picker or the key view that opens over the prompt keeps follow mode. The compose window counts as the prompt.

## The tool pane

Under the code window, the tool pane lists Claude's tool calls with their results. It has the terminal's background, and a tab in its bar says `Tool calls`. When the terminal does not report its background, the pane takes a darker shade of the code's. A blank line starts each run of calls, and the transcript keeps one dim line for the run, such as `⎿  7 tool calls · 1 failed`. While a subagent has focus, the pane lists that subagent's calls instead, and its bar names the agent in its color, as in `Tool calls · Explore 2`.

The pane is a quarter of the column's height. Drag the line above it, or use `:resize` in the code window, and the pane keeps its new share until anvim quits, also when the terminal resizes. In a terminal too short for both windows, the pane hides until there is room. Like the transcript, it takes no focus: a window key that would land on it skips it, a click on it leaves the cursor where it was, and the mouse wheel scrolls it from anywhere.

`<leader>us` hides the pane, and the tool calls then show in the transcript, as in Claude Code. Calls that were drawn before the switch stay where they are. anvim remembers the choice for the next start.

## Read-only buffers

File buffers are read-only. `:w` does nothing but say so, and format on save never runs. Claude makes every change, and buffers reload when files change on disk. Long lines in the code window wrap, and `<leader>uw` turns that off for code. anvim remembers the choice for the next start. Markdown and text files always wrap, with no spell checking.

## The command line

A `:` command line opens in a window over the code, titled "Command line", so it never looks like the prompt. Search with `/` and `?` opens there too, titled "Search". No row at the bottom of the screen is kept for them: messages show for a few seconds at the bottom right, and the statusline shows a macro recording.

## Moving between windows

The cursor moves between the code window and the prompt in one step: `Ctrl-W l` or `Ctrl-L` from any row of the code window, and `Ctrl-W h` or `Ctrl-H` back. Moving into the prompt leaves you in normal mode. Only insert commands start typing: `i`, `a` and the others in the prompt. In a file buffer, `i`, `a`, `I`, `A`, `o` and `O` go to the prompt and type where you stopped.

The transcript takes no focus. A window key that would land on it skips it, a click on it goes to the prompt, and the mouse wheel scrolls it from anywhere. It stops where the last line reaches the bottom of the window. New output keeps the transcript at its end, unless you scrolled up. Then it stays put until you scroll back down or send a prompt. To yank or search the transcript, enter read mode with `<leader>cr`, or drag across it with the mouse.

## The tab bar

Only one window shows files, so anvim always knows which file you are looking at. The bar at the top of the code window has a tab for each of the last 5 files that Claude read, edited, wrote or showed you. A tab keeps its place when Claude comes back to its file, and a new file pushes out the one that Claude touched longest ago. A `-` in Claude's color marks a file that Claude edited, and `(writing)` marks a new file while Claude writes it. The tab of the file that the code window shows stands out. A file that is not in the bar, such as one that you opened, shows at the left, apart from the tabs.

A click on a tab, or `Shift-H` and `Shift-L` in the code window, opens its file where you left it, or else where Claude was in it last. While you follow a subagent, the bar starts with the subagent's name and shows its files. A narrow code window drops tabs, first from the left, and shows how many it dropped on each side, such as `'2`. When you resume a session, the bar shows Claude's last files of that session again.

`<leader>cf` lists the same agent's last 25 files in a picker, newest first, with a preview. Each row says `Edit` or `Read` and how long ago the agent touched the file. `Enter` opens the file, and `@` puts a reference to it in the prompt. The cursor starts in the list, and `/` or `i` goes to the search.

A split, a picker's split action or `:diffsplit` opens the file in the code window instead. Help, quickfix, terminal and plugin windows open as usual. If you close the code window, the tool pane, the transcript or the prompt, anvim opens it again. `:q` in any of them quits anvim, also when other tabs are open.

## Images

In terminals with the kitty graphics protocol, such as Ghostty, cmux and kitty, the code window shows PNG images, and markdown files show their PNG images inline. Other image formats show as text. An image that changes on disk, such as a PNG that Claude writes again, shows its new picture, like any other buffer.

## Editor tools for Claude

Claude can also use your editor. It points at code with `show_user`, which marks a range and puts a short note above it until your next prompt. It asks the language servers that run in anvim for diagnostics, definitions, references, hover text and symbols, so it greps less. These tools work in every permission mode, so they read only files inside the directory that anvim opened. `show_user` can point at any file, because its answer holds no file text.
