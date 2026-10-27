# Install and run

<a id="install-update-and-uninstall"></a>

anvim runs its own Neovim configuration and keeps its plugins and state separate from your regular Neovim. You can try it without changing `~/.config/nvim`.

<a id="requirements"></a>

## Before you start

Install Neovim 0.12 or newer, Git and [Bun](https://bun.sh). Sign in with Claude Code (`claude auth login`), or add an account from anvim with `/account add personal`. For the full editor experience, also install ripgrep, a C compiler, curl, tar, gzip, Node.js and npm. They support search, parser builds and language server installation. A [Nerd Font](https://www.nerdfonts.com) gives the interface its icons. Google Chrome is needed for PNG output from the development screen tool and the debug screenshot tool.

On Linux, the Bash sandbox also needs `bwrap` and `socat`. If it cannot start, anvim warns and falls back to default permission mode unless you explicitly chose a mode. See [permissions](permissions.md#without-a-sandbox).

## Install

From the repository root:

```sh
scripts/install
mkdir -p ~/.local/bin
ln -s "$PWD/bin/anvim" ~/.local/bin/anvim
```

Add `~/.local/bin` to your `PATH` if necessary, for example in `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The installer uses `sidecar/bun.lock` and `lazy-lock.json` to install the sidecar and pinned plugins. It also installs the tree-sitter CLI, Lua, TypeScript and JSON language servers, and the configured parsers. It checks the required tools and warns about missing optional ones. Re-running it installs what is missing.

<a id="start"></a>

## Start a project

```sh
anvim ~/dev/project
```

The cursor starts in the prompt in normal mode: press `i`, write a request and press `Enter`. Explore the [screen](screen.md) and [prompt](prompt.md) for the next steps, or browse the [documentation index](index.md). By default Claude starts in bypass mode with a sandbox for Bash; understand its [limits](permissions.md) before you begin.

```sh
anvim --mode default ~/dev/project    # ask before operations that need approval
anvim --model haiku --effort high ~/dev/project
anvim --account personal ~/dev/project
anvim -c ~/dev/project                # continue the latest session in this directory
anvim --resume ~/dev/project         # choose a session
anvim --resume 12345678-1234-1234-1234-123456789abc ~/dev/project  # resume by session ID
```

The launcher accepts `--model`, `--effort` (`low`, `medium`, `high`, `xhigh`, `max`), `--mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`), `--account`, `--no-sandbox`, `--dangerously-skip-permissions`, `--chrome`, `--no-chrome`, `--no-codex`, `--debug`, and `-c`/`--continue` or `-r`/`--resume [id]`. Remaining arguments go to Neovim; if the first remaining argument is a directory, it selects the working directory. Continue and resume cannot be combined.

Environment equivalents are `ANVIM_MODEL`, `ANVIM_EFFORT`, `ANVIM_MODE`, `ANVIM_ACCOUNT`, `ANVIM_SANDBOX=0`, `ANVIM_CHROME=1` or `0`, `ANVIM_CODEX=0` and `ANVIM_DEBUG=1`. An explicit flag takes precedence. With no effort override, Claude Code's setting, then the model default, decides. With no Chrome override, Claude Code's “Enabled by default” setting decides. `--dangerously-skip-permissions` combines `--no-sandbox` with `--mode bypassPermissions`; see [what that means](permissions.md#without-a-sandbox).

<a id="update"></a>

## Update and troubleshoot

After `git pull`, start anvim normally. The launcher checks its install stamp against the lockfiles and the parser and package lists; if they changed, it runs the installer. If that fails and an earlier install exists, anvim warns, starts with the earlier install and retries next time. A first install failure stops startup. Set `ANVIM_NO_INSTALL=1` to skip automatic installation.

Run `:checkhealth anvim` to inspect dependencies, the selected account, sandbox, permission mode and Codex availability. The log is normally at `~/.local/state/anvim/anvim.log`. The installer's `scripts/install --check` checks the stamp without starting Neovim. `:Lazy update` changes the installed plugins; a later install after a lockfile change restores anvim's pinned commits. See [development](development.md#plugins) to update the repository's pins.

<a id="your-own-plugins"></a>

## Personal plugins and colors

Put lazy.nvim specs in `~/.config/anvim/lua/plugins/*.lua`. They load after anvim's specs, and their pins go in the install directory's lockfile, not the repository's. For example:

```lua
-- ~/.config/anvim/lua/plugins/colorscheme.lua
return {
  { "sainnhe/everforest", lazy = true },
}
```

`<leader>uC` previews and selects a colorscheme; anvim remembers your choice. The picker includes Neovim's schemes, the bundled schemes and lazy colorscheme plugins you add.

## Files and uninstall

With default XDG paths, anvim uses:

| Location | Contents |
| --- | --- |
| `~/.local/share/anvim` | Plugins, parsers, Mason packages, install stamp and personal-plugin lockfile; override with `ANVIM_INSTALL_DIR` |
| `~/.local/state/anvim` | Logs, undo history, prompt history and saved UI choices |
| `~/.cache/anvim` | Caches |
| `~/.config/anvim` | Your personal plugin specs |
| `sidecar/node_modules` | Sidecar dependencies in the checkout |

The first four follow the corresponding `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and `XDG_CONFIG_HOME` variables. Claude Code stores its own sessions and account data separately, normally under `~/.claude`.

To remove anvim's default directories and launcher link, use the command below, then remove the checkout if you no longer need it. This also deletes your anvim prompt history and personal specs; adjust the paths if you used XDG overrides.

```sh
rm -rf ~/.local/share/anvim ~/.local/state/anvim ~/.cache/anvim ~/.config/anvim ~/.local/bin/anvim
```
