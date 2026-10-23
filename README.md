# anvim

Claude Code, dressed as Neovim.

![anvim](docs/screenshot.png)

anvim is a read-only Neovim for watching Claude Code work. You read and point. Claude writes, and its edits stream into your buffers as it generates them. You cannot edit a file in anvim. If you want to edit code, open Neovim proper. If you want oversight over your agents, this might be for you.

It runs the real Claude Code engine through the Agent SDK, so your login, `CLAUDE.md` files, skills, MCP servers, hooks and settings work as they do in Claude Code. anvim only builds the view.

This is a personal productivity tool, and it is niche. There are no releases and no compatibility promise. Most of anvim was written inside anvim, and `anvim --debug` lets Claude keep going: it gets a tool that takes a picture of the screen, and one that restarts anvim with its own changes. Fork it and make it yours.

## Install

You need Neovim 0.12 or newer, git, [Bun](https://bun.sh) and Claude Code, logged in. [docs/install.md](docs/install.md) has the full list.

```sh
git clone https://github.com/davidbachmann/anvim.git
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

Three columns open: the explorer, the code and Claude. The cursor is in the prompt, in normal mode. Press `i`, type, and press `Enter`.

While your cursor is in the prompt, the code window follows Claude. It opens the files Claude reads, and edits stream in with the old text struck through. Move the cursor anywhere else to take control. `<leader>j` jumps back to where Claude is.

To point Claude at code, select lines and press `c`. That puts a reference such as `@src/app.lua#L12-30` in the prompt, and Claude Code reads those lines with your prompt. The buffers are read-only, so `c` is free. Read it as "change this, Claude".

Claude starts in bypass mode with Claude Code's sandbox on. It edits files and runs commands without asking, and the sandbox keeps its commands from writing outside the project. `anvim --mode default` asks first, as Claude Code does.

```sh
anvim --model haiku ~/dev/project     # pick a model
anvim --mode default ~/dev/project    # ask before edits and commands
anvim -c ~/dev/project                # go on with the latest session
anvim --resume ~/dev/project          # pick a session
anvim --debug ~/dev/anvim             # let Claude work on anvim itself
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

anvim is one person's workflow, written down as code. Yours differs. Fork the repo, change the keys, the layout and the rules, and point `anvim --debug` at your fork. Claude reads the screen, edits the code and restarts anvim in the same session, so you can shape it from the inside.

Issues and pull requests are welcome, but a fork that fits you is the better outcome.

## License

[MIT](LICENSE)
