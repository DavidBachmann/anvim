# Install, update and uninstall

## Requirements

- Neovim 0.12 or newer, git and [Bun](https://bun.sh)
- A C compiler, curl, tar and gzip, to build the treesitter parsers and to install the language servers
- Node.js with npm, for the TypeScript and JSON language servers
- [ripgrep](https://github.com/BurntSushi/ripgrep), for grep
- A [Nerd Font](https://www.nerdfonts.com) in the terminal, for the icons
- Claude Code, logged in (`claude /login`)
- Google Chrome, only for the screen tool

`scripts/install` checks the tools. It stops without Neovim, git or Bun, and warns about the others.

## Install

Clone the repo. Then, from its root:

```sh
scripts/install
mkdir -p ~/.local/bin
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

If `~/.local/bin` is not on your PATH, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile, such as `~/.zshrc`. `scripts/install` prints these steps when `anvim` is not on your PATH yet.

`scripts/install` installs the sidecar's packages from `sidecar/bun.lock`, and anvim's plugins with lazy.nvim at the commits in the repo's `lazy-lock.json`. With mason, it installs the tree-sitter CLI and the language servers for Lua, TypeScript and JSON. Then it builds the treesitter parsers. The first run takes about half a minute on a fast network. A second run installs only what is missing, and takes less than a second.

anvim brings its own Neovim config. It reads and writes nothing under your main Neovim's `~/.config/nvim` and `~/.local/share/nvim`. The two never share a plugin or a file.

## Start

```sh
anvim [--model <model>] [--effort <level>] [--mode <mode>] [--no-sandbox] [--dangerously-skip-permissions] [--chrome | --no-chrome] [--no-codex] [--debug] [-c | --continue | -r | --resume [id]] [dir] [nvim args...]
anvim --model haiku ~/dev/project
anvim --effort high ~/dev/project               # low, medium, high, xhigh or max
anvim --mode default ~/dev/project              # ask before Claude edits a file or runs a command
anvim --no-sandbox ~/dev/project                # let Bash commands write anywhere, and start in default mode
anvim --dangerously-skip-permissions ~/dev/project   # no sandbox, and no prompts
anvim --chrome ~/dev/project                    # let Claude use your Chrome through the Claude extension
anvim --no-codex ~/dev/project                  # no Codex agents, even with the codex CLI logged in
anvim -c ~/dev/project                          # go on with the latest session there
anvim --resume ~/dev/project                    # pick a session to go on with
```

Each flag has an environment variable: `ANVIM_MODEL`, `ANVIM_EFFORT`, `ANVIM_MODE`, `ANVIM_SANDBOX=0`, `ANVIM_CHROME=1` or `0`, `ANVIM_CODEX=0` and `ANVIM_DEBUG=1`. `--dangerously-skip-permissions` is short for `--no-sandbox --mode bypassPermissions`. A flag wins over its variable. To start in default mode every time, put `export ANVIM_MODE=default` in your shell profile.

Without `--effort` or `ANVIM_EFFORT`, the effort is the level in your Claude Code settings for the model, else the model's own. Without `--chrome` or `--no-chrome`, Claude Code's "Enabled by default" setting for Claude in Chrome decides. `--debug` is for work on anvim itself, see [development.md](development.md).

If `scripts/install` never ran, `anvim` runs it first.

## Update

```sh
git pull
anvim
```

When the repo's `lazy-lock.json` or `sidecar/bun.lock` changed since the last install, or the code that lists the mason packages and the parsers, `anvim` runs `scripts/install` before it starts. The install moves each plugin to the repo's commit, also back to an older one. If it fails, for example without a network, anvim warns, starts with the plugins it has, and tries again at the next start. A plugin of your own specs that fails to install only gets a warning. With `ANVIM_NO_INSTALL=1`, anvim installs nothing, not even at start.

Nothing that anvim does writes a tracked file, so `git pull` always works. `:Lazy update` in anvim updates the plugins in the install dir only. The next install after a pull that changes the repo's lockfile brings anvim's own plugins back to the repo's commits.

## Your own plugins

Your own specs go in `~/.config/anvim/lua/plugins/*.lua`. They load after anvim's, as lazy.nvim specs. lazy.nvim installs their plugins at the next start, and keeps their commits in the install dir's lockfile, `~/.local/share/anvim/lazy-lock.json`, never in the repo.

anvim starts with tokyonight. `<leader>uC` picks another colorscheme, with a live preview, and anvim remembers it for the next start. The picker lists Neovim's own colorschemes and the ones that anvim brings: catppuccin, rose-pine, kanagawa, nightfox, gruvbox and modus. Each loads only when you pick it. Add a colorscheme plugin with `lazy = true`, and the picker lists it too:

```lua
-- ~/.config/anvim/lua/plugins/colorscheme.lua
return {
  { "sainnhe/everforest", lazy = true },
}
```

## Files and uninstall

anvim's Neovim runs with `NVIM_APPNAME=anvim`, so its files are in dirs of their own:

- `~/.local/share/anvim`, the install dir: the plugins in `lazy/`, the parsers in `site/`, mason's packages in `mason/`, lazy.nvim's lockfile and the stamp of the last install. `ANVIM_INSTALL_DIR` puts it elsewhere.
- `~/.local/state/anvim`: the log, undo history, past prompts, the choices that you made with `<leader>u` keys, and the language servers' logs.
- `~/.cache/anvim`: caches.
- `~/.config/anvim`: your own specs, if you have any.
- `sidecar/node_modules` in the repo.

The first four follow `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and `XDG_CONFIG_HOME`. Claude Code keeps its sessions in `~/.claude`, as for the CLI. To uninstall anvim, remove its dirs and the link, and then the repo:

```sh
rm -rf ~/.local/share/anvim ~/.local/state/anvim ~/.cache/anvim ~/.config/anvim ~/.local/bin/anvim
```
