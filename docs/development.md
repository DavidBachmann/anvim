# Development

<a id="how-it-is-built"></a>

The fastest way to get oriented is to read [architecture](architecture.md), then trace the relevant event through `sidecar/src/protocol.ts` and `lua/anvim/sidecar.lua`. [CLAUDE.md](../CLAUDE.md) contains the project's working rules, test policy and traps. Keep user-facing documentation in step with behavior changes.

<a id="gates"></a>

## Tests and checks

Run the full set before a commit:

```sh
scripts/check
```

It runs formatting, lint, typechecks, sidecar tests, plugin specs, stack specs and attached-UI tests in parallel. For a focused iteration:

```sh
(cd sidecar && bunx tsc --noEmit && bun test)
scripts/test tests/stream_spec.lua
scripts/test-stack
scripts/test-ui tests/ui/mouse.test.ts -t drag
(cd tools/screen && bunx tsc --noEmit)
stylua --check . && selene .
```

`scripts/test` without a file runs all plugin specs in parallel shards; `ANVIM_TEST_SHARDS` sets the shard count (default four). Each shard runs multiple specs in one Neovim, so specs must not rely on another spec's state. `scripts/test-stack` boots the real `init.lua` in a child Neovim with temporary state. `scripts/test-ui` attaches a UI and can test actual frames, focus, resizing and mouse behavior that headless tests cannot see.

The test scripts call `scripts/test-deps`, which installs the locked plugins and a fixed lua-language-server into `.tests/anvim` and the screen tool dependencies into `tools/screen/node_modules`. The first installation needs a network connection; later runs can use the installed dependencies. The screen tool and UI tests share the UI client in `tools/screen/ui.ts`.

Use `--model haiku` for live runs and prefer replays when possible. For startup problems, run `:checkhealth anvim`; the default log is `~/.local/state/anvim/anvim.log`.

## Record and replay

```sh
ANVIM_RECORD=session.jsonl anvim --model haiku
ANVIM_REPLAY=session.jsonl anvim
```

A recording captures events for replay without an API call. Each prompt sent during replay plays the next recorded turn; background agent activity can continue after its turn. Fixtures in `tests/fixtures/` use `/ANVIM_FIXTURE` as a path placeholder. Preserve their recorded form; Stylua skips them.

## Plugins

`scripts/update-plugins` is the tool for changing the repository's `lazy-lock.json`:

```sh
scripts/update-plugins               # update all pinned plugins
scripts/update-plugins snacks.nvim   # update selected plugins
```

It first syncs the install directory to the current pins, then updates the requested plugins. It does not load personal specs. Run the checks and commit the resulting lockfile; colleagues' next startup installs the new pins.

## The screen tool

`tools/screen/screen.ts` starts an embedded anvim with the test plugins and drives its UI. A `snap` saves the grid as `.txt`, highlight information as `.hl.txt`, an SVG and, with Google Chrome available, a PNG. `record` captures frames and timing. Each run prints the path to its own temporary log.

```sh
bun tools/screen/screen.ts --cwd "$PWD" --size 200x48 \
  --replay tests/fixtures/write-session.jsonl --out /tmp/anvim-screen -- \
  'wait:2500' 'snap:start' 'record:1000'
```

The example takes a snapshot of the initial screen and records one second of frames. For a live run, omit `--replay` and add `--model haiku`. Live runs use the default account unless `ANVIM_ACCOUNT` or `CLAUDE_CONFIG_DIR` selects another. The header of `screen.ts` lists the available steps. If Chrome cannot run in the environment, inspect the text and highlight snapshots.

For real terminal key behavior, the project also uses a cmux split (`cmux new-split`, `cmux send`, `cmux send-key`, `cmux read-screen`); close it afterwards. Avoid system screenshots, which can capture unrelated workspaces.

## Debug mode

`anvim --debug` or `ANVIM_DEBUG=1` exposes two additional editor tools to Claude for developing anvim itself:

- `mcp__anvim__screenshot` returns the real terminal screen as text and a PNG. PNG capture needs Chrome; `CHROME` can name another binary. Images drawn by the terminal itself are absent from the capture.
- `mcp__anvim__reload` waits until Claude and its agents are idle, restarts anvim from the code on disk and resumes the session with the model, effort, mode and draft. Stop Claude to cancel a pending restart. Reload skips installation, so start normally after changing `lazy-lock.json`.

The restarted process runs the changed code with your full user rights, outside Claude's sandbox, without another approval prompt. Use debug mode only with code you intend to run.
