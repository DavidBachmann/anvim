# Permissions and the sandbox

By default, anvim starts in **bypass mode with the Bash sandbox enabled**. Claude can edit project files and run sandboxed commands without ordinary permission prompts. The sandbox restricts command writes, and anvim guards specific gaps described below. It does not protect your project from changes: keep your work in version control.

## Modes

Choose a starting mode with `--mode default`, `--mode acceptEdits`, `--mode plan` or `--mode bypassPermissions`. Set `ANVIM_MODE` in your shell to make a choice persistent; `--mode` overrides it. Without an explicit choice, anvim falls back to default mode if the sandbox is off or cannot start.

In default mode, Claude Code asks before edits and commands that need approval, subject to your Claude Code permission rules. `acceptEdits` accepts edits; plan mode keeps work read-only until a plan is approved. In the prompt, `Shift-Tab` cycles default, accept edits and plan, plus bypass if anvim started in bypass. The statusline shows a changed mode; plan mode always appears.

anvim's editor tools do not ask for permission. The `codex` tool is an exception: default and accept edits modes ask before it runs, bypass asks before a write-capable run, and plan mode runs it read-only. See [Codex agents](subagents.md#codex-agents) and [the gaps](#the-gaps).

<a id="requests"></a>

## Requests and plans

A permission request, question or plan approval appears at the bottom of the Claude column. An edit preview appears in the code window before its request; rejecting it restores the view of the file on disk. If you are elsewhere, the cursor stays put, the statusline says Claude is waiting, and anvim posts a notification. A request brings the transcript to the bottom, except while you are in read mode; leaving read mode brings it into view. `Esc` there returns to the prompt without answering. An answer key pressed while the request is out of view brings it into view first.

<a id="answering"></a>

### Answering a request

In the prompt's **normal mode**:

| Key | Action |
| --- | --- |
| `1`–`9` | Choose an option |
| `Enter` | Choose the highlighted option |
| `j`, `k` | Move between options |
| `Esc`, pause, `Esc` | Answer No |

If a request arrives while you are typing, you can finish your draft: digits remain text and `Enter` keeps the draft without sending or answering. Press `Esc` to leave insert mode, then choose. Choices are ignored for 0.4 seconds after the request opens or after your last typed character. After an answer, the prompt stays in normal mode.

The first `Esc` in normal mode arms No; press again after at least 0.4 seconds and within three seconds. See [stopping Claude](prompt.md#stopping-claude). Options such as “No, and tell Claude what to do differently”, “No, keep planning” and a question's “Other” accept text. `Enter` sends that text; two Esc presses return to the options. Your draft prompt is restored afterwards.

A request shows paths outside the working directory. “Yes, and don't ask again” displays and applies Claude Code's suggested rules, such as `Bash(npm test:*)`; project rules are saved in `.claude/settings.local.json`. Plan approval offers accept edits or manual approval, with bypass instead of accept edits when anvim started in bypass. Multi-select questions have a Submit option. Plans, questions and your answers remain in the transcript.

## The sandbox

Claude's Bash commands use Claude Code's sandbox: Seatbelt (`sandbox-exec`) on macOS and bubblewrap on Linux. By default, commands can write in the project, the sandbox temp directory and `$TMPDIR`, and the npm, Bun and Go build caches. They can read files outside those locations. The sandbox is designed to catch accidents, not to contain an agent trying to escape.

The sandbox applies to Bash; Edit and Write run outside it. anvim guards sensitive edit destinations separately. In default mode, read-only commands such as `ls` and `cat` normally run without a prompt, while other commands ask. Bypass mode runs commands without ordinary prompts, subject to the guards below.

When started in a subdirectory of a Git repository, the sandbox also permits writes in the repository root so commands such as `git add` and `git commit` work. Claude Code keeps `.git/config` and `.git/hooks` read-only. This additional root allowance does not apply when the repository root is your home directory, or in a linked worktree or submodule whose Git directory is elsewhere.

In default mode, a command connecting to a new host asks for network access. “Yes, and don't ask again” saves a `WebFetch(domain:<host>)` project rule, which also permits Claude's WebFetch tool to reach that host. In bypass mode, commands can connect to hosts without asking.

### The gaps

The following guards can prompt even in bypass mode. Their yellow explanation says why, and they offer no persistent “don't ask again” choice:

- **Unsandboxed Bash.** A command requesting `dangerouslyDisableSandbox` asks under “Bash command (unsandboxed)”.
- **Excluded commands.** Commands matching `sandbox.excludedCommands` run outside the sandbox, including entries from a repository's `.claude/settings.json`. anvim checks the list for each command and may ask more often than Claude Code's own parser: it considers command prefixes before an entry's first `*`, including after quotes, environment assignments and wrappers such as `timeout` or `sudo`. For example, `npm run *` catches `npm run build`, not `npm test`.
- **Edits outside trusted directories.** Trusted locations include the project, non-glob `sandbox.filesystem.allowWrite` entries (including the Git root and configured caches), the sandbox temp directory, and `projects/`, `plans/` and `agent-memory/` in the Claude config directory. The sandbox temp directory is `/tmp/claude-<uid>`, or `claude-<uid>` under `$CLAUDE_CODE_TMPDIR`; plain `/tmp` is not automatically trusted. Glob entries are not trusted by the edit guard, even if the Bash sandbox expands them. Symlinks are checked at their resolved destinations. Default mode combines this with its ordinary approval into one prompt.
- **Sandbox settings.** Editing the project's or Git root's `.claude/settings.json` or `.claude/settings.local.json` asks because these can expand `allowWrite` or exclude commands.
- **Configuration that runs code.** Claude Code's list includes directories such as `.git`, `.claude`, `.vscode` and `.husky`, and files such as `.mcp.json`, `.envrc`, `.npmrc`, `.zshrc` and `lefthook.yml`. MCP servers and Git hooks, for example, can run outside the sandbox later. For this configuration-file guard, the first `.claude/worktrees` path component is exempt, as in Claude Code; other guards can still apply. A hook script configured elsewhere remains a gap: editing it can affect a later hook without this guard.
- **Codex writes.** Codex has its own sandbox and can write project files, including configuration that anvim would guard for Claude. In bypass mode anvim asks before a write-capable Codex run, but not for a read-only run. In default and accept edits modes, Codex calls are subject to ordinary approval. Plan mode runs Codex read-only.

For Claude and each subagent, anvim sends the first guarded call back with a hint instead of immediately asking. The hint explains that you have not been asked, suggests an alternative and permits the agent to retry. Later guarded calls from that agent ask you. The transcript shows the send-back, and `~/.local/state/anvim/anvim.log` records send-backs and subsequent prompts with `send-back:`. `/clear` resets Claude's count. Write-capable Codex calls are the exception: they ask directly because there is no equivalent run inside Claude's sandbox. `--no-sandbox` disables these guards as well.

### Browser actions

Claude in Chrome acts in your real Chrome, with your sign-ins. Claude can use it, and Claude can give it to a Codex run (see [Codex agents](subagents.md#codex-agents)). Neither Claude Code's sandbox nor Codex's sandbox covers browser actions, and a read-only Codex run can still act in the browser. The extension's permission mode decides whether it asks in Chrome before it acts on a site. In bypass mode it skips those checks, and in every other mode it asks. Claude Code changes the mode of its own server when the session's mode changes. A Codex run gets the mode that applies when the run starts, and keeps it until the run ends.

### Without a sandbox

On Linux, install `bwrap` and `socat` to run the sandbox. If its pre-check fails or Claude Code cannot start it, anvim warns and uses default mode unless you explicitly chose a mode. `--no-sandbox` or `ANVIM_SANDBOX=0` turns it off and uses the same fallback without a warning; a personal spec can also set `sandbox = false`.

An explicitly chosen mode remains in effect. In particular, `--no-sandbox --mode bypassPermissions`, also spelled `--dangerously-skip-permissions`, lets Claude run commands and make edits without the sandbox guards or ordinary approval prompts. anvim's editor tools still enforce their own path restrictions. Questions and plan approvals still wait for you. `:checkhealth anvim` reports the sandbox state and starting mode, including why it was selected.

### Caches and other dirs

anvim allows sandboxed writes to npm's `~/.npm` (including `npx`), Bun's `~/.bun/install/cache`, and the Go build cache (`~/Library/Caches/go-build` on macOS or `~/.cache/go-build` on Linux). Those caches can contain code later run outside the sandbox. Bypass mode also allows Claude's edits there without a prompt.

To allow another cache, add it to your Claude Code settings, for example `~/.claude/settings.json`:

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": ["~/.cache/<tool>"]
    }
  }
}
```

Every sandboxed command can write to an allowed directory. On macOS, two additional settings can enable tools at a cost:

- `"network": { "allowUnixSockets": ["<path>"] }` with the real path of `$SSH_AUTH_SOCK` permits `ssh-add`. Every sandboxed command can then sign with your SSH keys, and the path changes on login. Git over SSH works without this setting.
- `"enableWeakerNetworkIsolation": true` enables tools such as `gh` and `pip` that consult the system trust service for TLS. The Agent SDK documentation warns that this can create a path for data to leave the machine.
