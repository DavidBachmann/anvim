# anvim

Claude Code, dressed as Neovim.

![anvim](docs/screenshot.png)

anvim is a read-only Neovim for overseeing agentic coding. It takes Claude Code a step further: your agents do the editing, and you keep every Vim motion and the full overview.

## Why read-only?

Claude Code's terminal shows a log: `Read(src/app.ts)`, then `Update(src/app.ts)`. anvim shows the code behind it.

- Follow Claude: the code window opens each file at the lines Claude reads.
- Watch edits stream in, with old text struck through. You see each change before it reaches disk.
- Track agents by their colored dots in the explorer. Follow one to see its reads and edits.
- Open the Agent Overview for each agent's task, context use and tool calls.

Leave the prompt to review code with LSP, grep, git log and diffs. `<leader>j` takes you back to Claude.

Claude writes; you review and point. To edit a file yourself, open Neovim proper. anvim reloads files that change on disk.

## What anvim rebuilds

The Agent SDK runs the real Claude Code engine. It brings your login, sessions and `CLAUDE.md` files.

Your skills, plugins, MCP servers, hooks, settings, permission rules, subagents and sandbox work as they do in Claude Code.

The SDK has no interface. anvim rebuilds Claude Code's interface:

- The transcript and tool pane.
- The prompt: `@` and `/` completion, past prompts and pasted images.
- `Ctrl-G` for long prompts, `Up` to retrieve queued prompts, `Ctrl-B` to background agents.
- Permission requests, Claude's questions and plan approval.
- The statusline: permission mode, model, effort and context use.
- `/resume`, `/model` and `/effort`; Settings for `/status`, `/usage`, `/context`, `/mcp` and `/chrome`.

Claude Code sends subagent edits whole; anvim types them into the buffer while you follow. It also finds files in Bash commands such as `cat` and `grep -n`.

MCP sign-in and paid cloud reviews still need Claude Code's terminal. So do terminal-only commands such as `/doctor`.

## Quality of life

- Timestamps. Every prompt, reply, tool call and notice shows when it arrived, in agent logs and resumed sessions too.
- `Esc` needs two presses with a pause to stop Claude or answer no. A burst does nothing.
- Typing never answers a permission request. Digits stay text, and `Enter` keeps your prompt.
- Focus never starts insert mode. Only insert commands such as `i`, `a` and `c` do.
- Prompts carry only what you write. anvim adds no hidden context.
- Keys follow LazyVim. Keys that change files do nothing.
- The transcript and tool pane take no focus. Scroll with the mouse wheel; drag to copy text.
- Notifications arrive only when anvim is out of sight.

## Install

You need Neovim 0.12 or newer, git, [Bun](https://bun.sh) and Claude Code, logged in. [docs/install.md](docs/install.md) has the full list.

```sh
git clone https://github.com/DavidBachmann/anvim.git
cd anvim
scripts/install
mkdir -p ~/.local/bin
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

anvim keeps its plugins, state and config apart from your main Neovim, and reads nothing from `~/.config/nvim`.

## Start

```sh
anvim ~/dev/project
```

The explorer, code and Claude open in three columns. The cursor starts in the prompt, in normal mode. Press `i`, type, then press `Enter`.

The code window follows Claude while your cursor stays in the prompt. Move elsewhere to review; `<leader>j` takes you back.

Select lines and press `c` to put a reference such as `@src/app.lua#L12-30` in the prompt. Claude Code reads those lines with your prompt. Read `c` as "change this, Claude".

Claude starts in bypass mode with the sandbox on. It edits files and runs commands without asking, and the sandbox keeps its commands from writing outside the project. `anvim --mode default` asks first.

```sh
anvim --model haiku ~/dev/project      # pick a model
anvim --mode default ~/dev/project     # ask before edits and commands
anvim --account personal ~/dev/project # use the login in ~/.claude-personal
anvim -c ~/dev/project                 # go on with the latest session
anvim --resume ~/dev/project           # pick a session
anvim --debug ~/dev/anvim              # let Claude work on anvim itself
```

`<leader>` is Space, and `<leader>?` lists every key.

## Docs

- [Install, update and uninstall](docs/install.md)
- [The screen](docs/screen.md): the columns, follow mode, the tool pane, the tab bar
- [The prompt](docs/prompt.md): references, the compose window, images, past prompts
- [Keys](docs/keys.md)
- [Sessions and slash commands](docs/sessions.md)
- [The transcript](docs/transcript.md)
- [Subagents](docs/subagents.md)
- [Permissions and the sandbox](docs/permissions.md)
- [Development](docs/development.md): the gates, record and replay, the screen tool

## Make it yours

anvim is one person's workflow, with no releases or compatibility promise. Most of anvim was written inside anvim. `anvim --debug` lets Claude keep going: it reads the screen and restarts anvim with its own changes.

Fork the repo, change what bothers you, and point `anvim --debug` at your fork. Issues and pull requests are welcome, but a fork that fits you is the better outcome.

## License

[MIT](LICENSE)
