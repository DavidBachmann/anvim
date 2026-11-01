# Architecture

anvim is a Neovim interface to the Claude Code engine. A Bun sidecar runs the Claude Agent SDK; the Lua plugin owns the screen and editor state. They exchange one JSON object per line over the sidecar's standard input and output:

```text
bin/anvim → Neovim + lua/anvim  ⇄  Bun sidecar  →  Agent SDK / Claude Code
                                  JSON lines
```

The SDK supplies the engine, including Claude Code's authentication, settings, sessions, hooks and tools. anvim supplies the viewer, prompt, editor tools and permission interface. The launcher sets `NVIM_APPNAME=anvim` and starts the repository's `init.lua`, isolating anvim's Neovim state from your usual configuration.

## From a prompt to the screen

1. The plugin starts the sidecar with a working directory and session options. The sidecar adds [anvim's paragraph](#what-anvim-tells-claude) to Claude Code's system prompt. A submitted prompt is sent as text, with image paths when present. anvim does not automatically attach the file or selection on screen to the user message; use a [reference](prompt.md#pointing-at-code).
2. `sidecar/src/main.ts` runs the SDK session. `translate.ts` translates SDK messages into events, and `fieldstream.ts` extracts incremental tool-input fields. `protocol.ts` defines both directions of the wire contract.
3. `lua/anvim/sidecar.lua` receives events. The transcript, tool pane, agent state and follow mode consume them to update the interface. Follow mode tracks file activity without taking control away when the user leaves the prompt.
4. Claude's editor tools travel in the other direction: `tools.ts` sends an `editor_request`; Lua performs the operation and replies with `editor_response`. Requests are asynchronous. Most tools restrict paths to the working directory; `show_user` can point outside it because it returns no file contents.

## How an edit reaches disk

Edit, Write and NotebookEdit use a preview handshake. Tool input streams into Lua, where `stream.lua` displays the proposed change. A pre-tool hook emits `await_preview`; the plugin replies `preview_done` when it catches up. The sidecar waits at most three seconds, or five for a subagent. After the tool result, the buffer reloads from disk. A rejected edit returns the view to the file on disk.

Subagent inputs arrive as whole messages, so anvim animates their preview only when that agent is followed. Bash and Codex changes do not stream as Edit/Write previews; open buffers reload after the change. The timeout is a fallback, so the preview is not a guarantee that disk can never change before the animation finishes.

## Permissions and sessions

`permissions.ts` bridges SDK permission requests to the UI. `sandbox.ts` configures the Bash sandbox and guards its gaps; `sendback.ts` can return the first guarded call to an agent with a hint before asking the user on a later call. Read [permissions](permissions.md) for the actual boundaries and exceptions. `codex.ts` runs Codex agents separately in their own sandbox.

Claude Code owns session persistence. `sessions.ts` reads saved sessions, and `replay.ts` plays recordings for development. anvim renders history but does not write Claude Code's session files itself.

## What anvim tells Claude

anvim keeps Claude Code's own system prompt and adds one short paragraph to it. [`sidecar/src/systemprompt.ts`](../sidecar/src/systemprompt.ts) holds the whole paragraph: how the user reads code, when to use the editor tools and how to keep the todo list. Only the main agent gets it. With `--amnesia`, one more line says that the session is temporary.

Your prompts reach Claude as you typed them, with any pasted images. anvim never adds the file or the selection on screen. The other text that anvim puts in Claude's context comes from these files:

- `sidecar/src/tools.ts`: the descriptions and results of the `mcp__anvim__*` tools.
- `sidecar/src/todos.ts`: the open todo items, as hook context when a session starts, resumes, clears or compacts.
- `sidecar/src/permissions.ts`: a fixed reply when you reject or cancel a permission request, with your message if you give one.
- `sidecar/src/sendback.ts`: the hint that replaces the result of each agent's first guarded call.
- `sidecar/src/hooks.ts`: the reason why a subagent cannot use the todo tools.
- `sidecar/src/agentfiles.ts`: a note after Claude writes an agent file, which says when the agent can run.
- `sidecar/src/codex.ts`: a Codex agent's result, as a task notification.
- `lua/anvim/reload.lua`: with `--debug`, the prompt after a restart, which names the commit that anvim runs.

## Where to look

- `lua/anvim/base/` contains editor options, mappings and plugin installation; `lua/anvim/plugins/` layers anvim's plugin specs on top.
- `layout.lua` and `windows.lua` manage the layout; `follow.lua`, `stream.lua` and `bashread.lua` track and display agent activity.
- `input.lua`, `completion.lua`, `compose.lua`, `transcript.lua` and `tools.lua` implement the conversation surfaces.
- `agents.lua`, `overview.lua` and `agentlog.lua` manage agent views; `sessions.lua` handles session and command UI.
- `keys.lua` owns mapping descriptions; changes must also satisfy the key drift tests.
- `tools/screen/` embeds an attached Neovim UI for screenshots and frame-level tests.

For setup, tests and replay commands, see [development](development.md). The protocol types and source are the authoritative reference when changing behavior on either side of the boundary.
