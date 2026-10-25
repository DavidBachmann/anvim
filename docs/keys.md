# Keys

`<leader>` is Space. `<leader>?` shows every key of anvim in one view, grouped by where it works, as in the tables below. In the prompt, `?` in normal mode shows it too. While you type, `?` shows it only when the prompt is empty and no request waits. Otherwise it types a `?`. A dim tag names the mode of a key that does not work in normal mode, such as `insert` or `visual`. `j` and `k` scroll the view when it does not fit. `q`, `Esc` or `:q` closes it, and the cursor goes back where it was, in the same mode. Vim's own keys work as usual.

The keys for reading sit where LazyVim puts them, so a LazyVim user finds them at once. Keys that edit, such as code actions, rename and window splits, are left out. So are Neovim's own keys that only change text: `gc` and `gcc`, which comment, `[<Space>` and `]<Space>`, which add blank lines, and `&`, which repeats a substitution. In operator-pending mode `gc` stays, because it selects a comment: `cgc` points Claude at one. In the explorer, the keys that add, delete, rename, copy, move and paste files do nothing, and so does `Ctrl-C`, which would change the working directory. In the git logs, `Enter` goes to the commit's diff and never checks out. Git status and the diff picker stage with `Tab`, but cannot restore.

## Everywhere

| Key | Action |
| --- | --- |
| `<leader>?` | Show every key of anvim |
| `Ctrl-H`, `Ctrl-J`, `Ctrl-K`, `Ctrl-L` | Go to the window on the left, below, above or on the right |
| `Shift-H`, `Shift-L` | Previous and next buffer, outside the code window |
| `j`, `k` | Move by screen line in wrapped text, by line with a count |
| `Esc` | Clear the search highlight |
| `<leader><space>`, `<leader>/`, `<leader>,` | Find files, grep, buffers |
| `<leader>fr` | Recent files |
| `<leader>e` | Toggle the explorer |
| `<leader>sw` | Grep the word under the cursor, or the selection |
| `<leader>ss`, `<leader>sS` | Symbols of the file, of the workspace |
| `<leader>sd`, `<leader>sD` | Diagnostics of the workspace, of the file |
| `<leader>sh` | Help pages |
| `<leader>lr` | Restart the language servers, for example when they missed a change on disk |
| `<leader>gs`, `<leader>gd` | Git status, git diff by hunk |
| `<leader>gl`, `<leader>gf`, `<leader>gb` | Git log, the file's history, the line's history |
| `<leader>uw`, `<leader>ud` | Toggle wrap in the code window, toggle diagnostics |
| `<leader>uH` | Toggle Claude on the left and the explorer on the right |
| `<leader>us` | Toggle the tool pane |
| `<leader>ue` | Toggle explorer auto-minimize |
| `<leader>uC` | Pick a colorscheme, with a live preview |
| `q` | Close a help, quickfix or info window |

## Code window

| Key | Action |
| --- | --- |
| `i`, `a`, `I`, `A`, `o`, `O` | Go to the prompt and type where you stopped |
| `c` in visual mode | Put a reference to the selected lines in the prompt |
| `c{motion}`, `cc` | Put a reference to the lines of the motion, or to the current line, in the prompt |
| `<leader>cb` | Put a reference to the selection, or to the whole file, in the prompt |
| `Shift-H`, `Shift-L` | Open the previous and next tab of the bar, around the ends. A click opens a tab |
| `gd`, `gr`, `gI`, `gy`, `gD` | Definition, references, implementation, type definition, declaration, in a buffer with a language server |
| `K` | Hover |
| `gO` | List the file's symbols |
| `]]`, `[[` | Next and previous reference to the word under the cursor, in a buffer with a language server |
| `]d`, `[d`, `]D`, `[D` | Next, previous, last and first diagnostic |
| `Ctrl-W d` | Show the diagnostics at the cursor |
| `]h`, `[h`, `]H`, `[H` | Next, previous, last and first hunk |
| `<leader>ghp`, `<leader>ghb` | Preview the hunk, blame the line |
| `gx` | Open the path or link under the cursor with the system app |
| `ii`, `ai` | The scope inside its edges, the scope with its edges, as text objects: `cii` points Claude at a block |
| `[i`, `]i` | Go to the scope's top and bottom edge |

## Prompt

| Key | Action |
| --- | --- |
| `Enter` | Send, and go back to normal mode. On the selected agent count, open the Agent Overview |
| `Shift-Enter`, `Alt-Enter` | New line, in insert mode |
| `Esc`, a pause, `Esc`, in normal mode | Stop Claude |
| `Ctrl-C`, `:AnvimStop` | Stop Claude at once |
| `Ctrl-B`, in insert mode | Move the running agents and Bash commands to the background |
| `Shift-Tab` | Cycle the permission mode |
| `Ctrl-G` | Write the prompt in a large window |
| `j`, `Down` on the last line, in normal mode | Select the agent count in the footer, while agents run |
| `k`, `Up`, `Esc` | End the selection of the agent count |
| `f` on the selected agent count | Follow the next agent, and Claude after the last |
| `Up` on the first line, `Ctrl-P` | Take the queued prompts back into the prompt, to change them, while prompts are queued |
| `Up` on the first line, `Down` on the last | Go back and forth through past prompts, in insert mode |
| `Ctrl-P`, `Ctrl-N` | Go back and forth through past prompts, in normal mode |
| `Ctrl-U`, `Ctrl-D`, `Ctrl-B`, `Ctrl-F` | Scroll the transcript, in normal mode |
| `PageUp`, `PageDown` | Scroll the transcript |
| `@`, `/` | Complete a file, or a slash command at the start, in insert mode |
| `?` | Show every key of anvim, in normal mode or in an empty prompt |
| `Ctrl-Space`, `Ctrl-E` | Show and close the completion menu, in insert mode. `Ctrl-Space` also completes words from the open files |
| `Ctrl-N`, `Ctrl-P`, `Up`, `Down` | Next and previous item, while the menu is open |
| `Ctrl-Y`, `Enter` | Accept the highlighted item |

## Compose window

| Key | Action |
| --- | --- |
| `Ctrl-G` | Put the text back in the prompt and go there |
| `:w` | Put the text in the prompt, and keep the window open |
| `:wq`, `ZZ` | Put the text in the prompt, and close the window |
| `:q!` | Drop the changes |

## Explorer

| Key | Action |
| --- | --- |
| `@` | Put a reference to the file in the prompt |
| `Ctrl-H`, `Ctrl-L`, `Ctrl-W h`, `Ctrl-W l` | Go to the code window |
| `?` | Show the explorer's own keys |

## Transcript and read mode

| Key | Action |
| --- | --- |
| `q`, `Esc` | Go back to the prompt |
| `i`, `a`, `I`, `A`, `o`, `O` | Go back to the prompt and type |
| Mouse drag | Select text, and copy it to the clipboard when you let go |
| Mouse wheel | Scroll the transcript or the tool pane, from any window |

## Permission requests

These keys work in the prompt, in normal mode, while Claude waits for your answer.

| Key | Action |
| --- | --- |
| `1` to `9` | Choose that option |
| `Enter` | Choose the highlighted option |
| `j`, `k` | Move to the next or previous option |
| `Esc`, a pause, `Esc` | No |

## Claude and its agents

| Key | Action |
| --- | --- |
| `<leader>j`, `<leader>cj` | Jump to where Claude, or the focused subagent, is |
| `<leader>c1` to `<leader>c4` | Focus the subagent with that number, so follow mode follows it |
| `<leader>c0` | Focus Claude, the main agent, again |
| `<leader>ca` | Open the Agent Overview: pick an agent to focus, with its place in the preview |
| `<leader>ct`, `:AnvimTrail` | Pick a place from Claude's trail |
| `<leader>cf` | Pick one of the last 25 files of Claude or the followed subagent |
| `<leader>cr`, `:AnvimTranscript` | Read the transcript: put the cursor in it to yank and search |
| `<leader>cy` | Yank Claude's last reply to the clipboard |
| `<leader>cs`, `:AnvimSessions` | Resume a session of this directory |
| `<leader>cm`, `:AnvimModel` | Choose Claude's model |
| `<leader>cR`, `:AnvimRestart` | Start Claude again, in the same session |
