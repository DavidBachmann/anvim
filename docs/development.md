# Development

## How it is built

```
nvim + lua/anvim  <-- JSON lines over stdio -->  sidecar (Bun + Agent SDK)  -->  Claude Code engine
```

The Agent SDK runs the real Claude Code engine, so sessions, auth, skills, MCP servers, hooks and settings come for free. anvim builds only the view.

- `bin/anvim` runs `nvim -u init.lua` with `NVIM_APPNAME=anvim`, so anvim's state, plugins and logs stay apart from the main Neovim's.
- `lua/anvim/base/` is the editor under the layout: a lean copy of LazyVim's options, keymaps and plugin specs. `lua/anvim/plugins/` is anvim's own lazy.nvim spec on top of it. The other files in `lua/anvim/` are named after their concern.
- `sidecar/src/` is the Bun process. `main.ts` runs the session, `translate.ts` turns SDK messages into protocol events, `protocol.ts` is the contract between the two sides, `tools.ts` is the editor tools' MCP server, `permissions.ts` bridges `canUseTool`, `sandbox.ts` holds the sandbox guards, and `codex.ts` runs the Codex agents.
- `tools/screen/` embeds anvim as a UI and records what Neovim draws.

`CLAUDE.md` holds the rules and the traps for work on the code.

## Record and replay

```sh
ANVIM_RECORD=session.jsonl anvim --model haiku   # save every event
ANVIM_REPLAY=session.jsonl anvim                 # play it back, with no API cost
```

Each prompt you send during a replay plays the next recorded turn. The work of a background subagent plays on after its turn ends. The fixtures in `tests/fixtures/` are recordings like these, with `/ANVIM_FIXTURE` as a path placeholder.

## Gates

`scripts/check` runs every gate side by side and prints one line per gate. These must pass before a commit. The Lua checks need `stylua` and `selene` on your PATH.

```sh
scripts/check                                     # every gate below, side by side
cd sidecar && bunx tsc --noEmit && bun test       # sidecar typecheck and tests
scripts/test [tests/stream_spec.lua]              # plugin specs, against a replayed fixture
scripts/test-stack                                # the real init.lua in a child Neovim
scripts/test-ui [tests/ui/mouse.test.ts -t drag]  # attached-UI tests, frame by frame
cd tools/screen && bunx tsc --noEmit              # typecheck the screen tool and the UI tests
stylua --check . && selene .                      # Lua format and lint
```

Each test script first runs `scripts/test-deps`. It installs anvim's plugins at the lockfile's commits, with the same code as `scripts/install`, and mason's lua-language-server, into `.tests/anvim`. It also installs the screen tool's packages into `tools/screen/node_modules`, which the UI tests share. Its first run needs the network, and later runs work offline.

`scripts/test` runs the Neovim specs in `tests/`, with test plugins of its own in `.tests/`. mini.test runs many specs in one Neovim, so no spec may depend on another spec's state. `scripts/test-stack` boots the real `init.lua` in a child Neovim, with the plugins from `.tests/anvim` and temporary state dirs. It checks that anvim installs and writes nothing there, nor in your main Neovim's dirs. `scripts/test-ui` embeds anvim with a UI attached and checks the frames it draws: splits that fold back, the cursor after a close, mouse drags, resizes, permission prompts typed at a user's pace, and a selection pinned while Claude reads elsewhere.

Use `--model haiku` for every live run. Prefer replays, which cost nothing. Run `:checkhealth anvim` when something does not start. The log is at `~/.local/state/anvim/anvim.log`.

## Plugins

The repo's `lazy-lock.json` holds the commits of anvim's own plugins, and only `scripts/update-plugins` writes it:

```sh
scripts/update-plugins               # every plugin
scripts/update-plugins snacks.nvim   # only these
```

It first brings your install dir to the repo's commits, and then updates the plugins there to their newest commits. It reads none of your own specs, so their plugins stay out of the repo's lockfile. Commit the new lockfile after the tests pass. After a pull, each colleague's next start installs the new commits.

## The screen tool

`tools/screen/screen.ts` drives anvim headless and saves text, highlight and PNG snapshots of the real screen. It boots the plugins in `.tests/anvim`, as the UI tests do, and shares its UI client, `tools/screen/ui.ts`, with them. A snap writes the grid as `.txt`, the highlights as `.hl.txt`, and an `.svg` and a `.png`. The PNG needs Google Chrome. `record` logs every frame with its timing. A run keeps its own log in a temp dir, and prints its path. A live run uses the `default` account, so no account picker asks. `ANVIM_ACCOUNT` or `CLAUDE_CONFIG_DIR` picks another one.

```sh
bun tools/screen/screen.ts --cwd <dir> --size 200x48 [--replay rec.jsonl | --model haiku] --out <dir> -- \
  'wait:2500' 'keys:Add a comment<CR>' 'waitfor:--- Returns' 'snap:mid' 'record:5000'
```

See the header of `screen.ts` for every step.

## Debug mode

`anvim --debug`, or `ANVIM_DEBUG=1`, is for work on anvim itself. It gives Claude two more editor tools.

`mcp__anvim__screenshot` takes a picture of your anvim screen as your terminal shows it. The tool returns the screen's text and a PNG, which needs Google Chrome (`CHROME` names another binary). Images that the terminal draws, such as PNG files in the code window, are not in the picture.

`mcp__anvim__reload` restarts anvim with the code on disk once Claude's turn ends and no agent runs. The new anvim resumes the session, with its model, effort, mode and prompt draft, and tells Claude that it restarted and which commit it runs. Stop Claude to cancel a restart that waits. The new anvim runs the code that Claude wrote with your full rights, outside the sandbox, and no prompt asks first. The restart skips `scripts/install`, so a changed `lazy-lock.json` needs a normal start.
