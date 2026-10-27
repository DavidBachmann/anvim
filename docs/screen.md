# The screen

anvim starts with three columns: the explorer, the code window, and Claude's transcript and prompt. A tool pane sits below the code. The cursor starts in the prompt in normal mode; press `i` when you want to type.

<a id="follow-mode"></a>

## Follow and review

While focus is in the prompt, the code window follows Claude through files it reads and edits. Edit and Write previews show old text struck through and new text as it arrives. anvim also recognizes reads in common Bash commands such as `cat`, `head`, `tail`, `sed -n`, `nl` and `grep -n`. A change made by Bash does not stream; an open buffer reloads after the command. Subagent and Codex edits have their own [limitations](subagents.md).

Move to another window to review independently. The statusline shows Claude's last location, for example `⏺ Claude at stream.lua:40 +2`; `<leader>j` jumps there. Return to the prompt to follow again. The compose window and pickers opened over the prompt keep follow mode active.

The statusline calls this mode `FOLLOW`. It uses absolute line numbers with a stable gutter during a streamed edit; a number too wide for the gutter appears blank until you leave follow mode. In review mode the code window uses its configured number setting. On narrow screens the statusline progressively drops details to fit.

<a id="the-explorer"></a>

## Explorer and code

`<leader>e` toggles the explorer. In its list, `q` or `Esc` hides it. It starts at 30 columns and expands over the code while focused to fit names. `<leader>ue` turns off auto-minimize, making the split fit its names up to 40% of the screen. `<leader>uH` swaps the sides of Claude and the explorer. These choices persist; the explorer reappears on the next start.

<a id="read-only-buffers"></a>

File buffers are read-only: `:w` reports that, and format-on-save does not run. Claude or another program can change the file on disk, and anvim reloads it. Code wraps by default; `<leader>uw` toggles and remembers wrapping. Markdown and text always wrap without spell checking. The [key reference](keys.md) covers search, LSP, Git and navigation.

<a id="the-tab-bar"></a>

The bar above the code shows the followed agent's last five files. A colored `-` marks a file it edited; `(writing)` marks a new file being written. Click a tab or use `Shift-H`/`Shift-L` in the code window to return to a file. `<leader>cf` opens a searchable picker of the last 25 files, with previews; `Enter` opens one and `@` references it in the prompt. A file you opened yourself appears separately if it is not among those tabs. Resuming a session restores Claude's recent files.

Only one window displays project files. A split or diff-split action opens the file in the code window instead. Help, quickfix, terminal and plugin windows can still open. If a core window is closed, anvim restores it; `:q` in a core window quits anvim.

## The tool pane

The pane below the code lists tool calls and results for Claude or the followed agent. Its bar names the agent and elapsed run time when applicable. The transcript summarizes each run. Drag the pane's top border or use `:resize` in the code window to change its share of the column for this run. It hides temporarily when the terminal is too short.

The pane takes no focus; use the mouse wheel to scroll it. `<leader>us` hides it and sends subsequent tool calls to the transcript. Calls already drawn stay where they are, and the choice persists across starts. `Ctrl-O` toggles full tool input and output; see [the transcript](transcript.md#tool-output).

<a id="the-command-line"></a>
<a id="moving-between-windows"></a>

## Moving around

`Ctrl-H`, `Ctrl-J`, `Ctrl-K` and `Ctrl-L` move between windows. From the code window, `Ctrl-L` goes straight to the prompt; `Ctrl-H` returns. In a file buffer, `i`, `a`, `I`, `A`, `o` or `O` moves to the prompt and starts typing. The transcript and tool pane are skipped by window navigation. To search or yank the transcript, use [read mode](transcript.md#scroll-search-and-copy).

The `:` command line and `/` or `?` search open in a window over the code, separate from the prompt. Messages appear briefly at the bottom right; the statusline indicates macro recording.

<a id="images"></a>
<a id="editor-tools-for-claude"></a>

## Images and editor tools

Terminals supporting the kitty graphics protocol, including Ghostty, cmux and kitty, can display PNG, JPG, GIF, WebP, BMP and TIFF in the code window and inline in Markdown. GIFs show their first frame. Bun converts non-PNG images and limits large images to 1920×1080; snacks.image uses ImageMagick when available. Changed image files reload.

Claude can use anvim's editor tools to show a location with a note, inspect diagnostics, and ask language servers for definitions, references, hover text and symbols. The note remains until your next prompt. These tools can run in every permission mode; tools that return file content restrict paths to the working directory, while `show_user` may point outside it. See [architecture](architecture.md#from-a-prompt-to-the-screen).
