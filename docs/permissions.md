# Permissions and the sandbox

## Modes

anvim starts in bypass mode, with the sandbox on: Claude edits files and runs commands in the project without asking. The sandbox keeps its Bash commands from writing outside the project, and anvim still asks where the sandbox has gaps (see [The sandbox](#the-sandbox)). Without a sandbox, anvim starts in default mode instead, unless you chose a mode.

Start it with `--mode default`, `--mode acceptEdits` or `--mode plan` for another mode. Default mode asks before Claude edits a file or runs a command, as Claude Code does, unless your Claude Code settings allow it. anvim's editor tools never ask, except `codex`, which starts a Codex agent that can write files ([subagents.md](subagents.md#codex-agents)). Default and accept edits mode ask before it runs, bypass mode asks before a run that writes ([The gaps](#the-gaps)), and plan mode runs it read-only. To start in another mode by default, put `export ANVIM_MODE=default`, for example, in your shell profile. `--mode` wins over it.

`Shift-Tab` in the prompt cycles default, accept edits and plan mode, plus bypass when anvim started in it. The statusline shows the mode after the mode block only while it differs from the one anvim started in, such as `⏵⏵ accept edits on`, or `⏵ manual mode on` for default mode. Plan mode always shows.

## Requests

When Claude needs your yes, the request appears at the bottom of the Claude column, as in Claude Code. An edit streams into the code window before the request opens, so you see the change before you answer. If you say no, the buffer shows the file on disk again. Claude's questions and its plan, when it wants to leave plan mode, appear the same way.

If your cursor is outside the prompt, anvim leaves it there, posts a notification and shows "⏺ Claude is waiting" in the statusline. A request brings the transcript to its end, even if you scrolled it up. In read mode the transcript stays where you read, and it goes to the request when you leave read mode. `Esc` there takes you back to the prompt and answers nothing. A choice key never answers a request that is out of view: it brings the request into view instead.

### Answering

These keys work in the prompt, in normal mode, while Claude waits:

| Key | Action |
| --- | --- |
| `1` to `9` | Choose that option |
| `Enter` | Choose the highlighted option |
| `j`, `k` | Move to the next or previous option |
| `Esc`, a pause, `Esc` | No |

While a request waits, normal mode in the prompt is for choosing. Typing your prompt never answers: if you are typing when a request opens, you keep typing, digits are text, and `Enter` keeps your prompt without sending it or answering. Press `Esc`, then choose. The line above the prompt says which keys answer, and in insert mode it starts with `esc to leave insert mode`. A choice also does nothing within 0.4 s of the request opening or of the last character you typed. Going to the prompt while Claude waits leaves you in normal mode. After you answer, the prompt stays in normal mode, also if you were typing before.

`Esc` answers No only when you press it twice, with a pause of at least 0.4 s between the presses and within 3 s. The first press only arms it, and the request shows that choice in red. See [prompt.md](prompt.md#stopping-claude).

"No, and tell Claude what to do differently", "No, keep planning" and a question's "Other" take typed text. `Enter` sends it, and `Esc` twice goes back to the options. Your draft prompt comes back afterwards. If Claude Code names a path outside the working directory, the request shows it. "Yes, and don't ask again" names the rules that Claude Code suggests, such as `Bash(npm test:*)`, and applies them all. Claude Code saves project rules in the project's `.claude/settings.local.json`. Plan approval offers Claude Code's choices: accept edits or manual approval, with bypass in place of accept edits when anvim started in bypass mode. The plan stays in the transcript. A multi-select question has a Submit option after its choices. Your answers stay in the transcript too, also with the tool pane on, as in Claude Code: `User answered Claude's questions:`, then each question with your answer, typed text included.

## The sandbox

anvim runs Claude's Bash commands in Claude Code's own sandbox: Seatbelt (`sandbox-exec`) on macOS, and bubblewrap on Linux. A command can write only in the project, in the sandbox's temp dir, `$TMPDIR`, and in the caches of npm, bun and go build. So an accidental `rm -rf ~/something` fails with "Operation not permitted". Commands can still read every file.

The sandbox catches accidents. It does not stop an agent that tries to get out, and it does not protect the project itself, so keep your work in git. In default mode, Claude asks before a command as it does without the sandbox: read-only commands such as `ls` and `cat` run without a prompt, and the others ask. Bypass mode runs commands without asking, but still in the sandbox.

When you start anvim in a subdirectory of a git repo, the sandbox lets commands write in the repo's root too, so that `git add` and `git commit` work. Claude Code keeps `.git/config` and `.git/hooks` read-only, so `git config` fails. This does not apply in a linked worktree or a submodule, whose git dir is elsewhere.

A command that connects to a new host asks first, in default mode: "Network access" names the host. "Yes, and don't ask again" saves a `WebFetch(domain:<host>)` rule in the project's `.claude/settings.local.json`. That rule also lets Claude's WebFetch tool reach the host without a prompt. In bypass mode, a command can connect to any host without asking.

### The gaps

The sandbox has gaps, and anvim asks at each of them, in every mode, bypass mode too. The prompt says why in a yellow line, and it has no "don't ask again", because anvim would ask again anyway:

- When a command fails in the sandbox, Claude often runs it again outside the sandbox, with `dangerouslyDisableSandbox`. anvim asks first, under the title "Bash command (unsandboxed)", with the line "runs outside the sandbox".
- A command that matches `sandbox.excludedCommands` in a settings file runs outside the sandbox, and a repo's own `.claude/settings.json` can list such commands. anvim asks: "runs outside the sandbox (excluded command)". It reads the list from Claude Code for each command. It asks for any command line in which a command, after quotes, `VAR=value` words and wrappers such as `timeout` or `sudo`, starts with an entry's words before its first `*`: with `npm run *`, `npm run build` asks and `npm test` does not. That is more often than Claude Code lets a command out, because Claude Code's parser has forms that anvim cannot follow.
- Claude's Edit and Write tools run outside the sandbox. anvim asks for an edit outside the trusted dirs: "outside the trusted dirs: ~/notes.txt". Default mode asks there anyway, and it stays one prompt. The trusted dirs are the project, the dirs in `sandbox.filesystem.allowWrite` (the git root above the project and the npm, bun and go build caches among them), the sandbox's temp dir `/tmp/claude-<uid>` (or `claude-<uid>` in `$CLAUDE_CODE_TMPDIR`), and `projects/`, `plans/` and `agent-memory/` in Claude Code's config dir, which hold its memory, its plans and the memory of subagents. Plain `/tmp` asks. Symlinks count where they lead, so a link in the project that points to `~` asks too.
- An edit of the project's `.claude/settings.json` or `.claude/settings.local.json`, or of those in the git root, asks: "changes the sandbox's settings". These files can widen the sandbox, for example with `allowWrite` or `excludedCommands`.
- An edit of a file that tools read as config and run, from Claude Code's own list, asks: "changes a config that runs outside the sandbox". The list has dirs such as `.git`, `.claude`, `.vscode` and `.husky`, and files such as `.mcp.json`, `.envrc`, `.npmrc`, `.zshrc` and `lefthook.yml`. An MCP server in `.mcp.json` runs outside the sandbox, and a git hook in `.git/hooks` runs when you use git in your own terminal. Default mode asks for these anyway, and it stays one prompt. As in Claude Code, edits in `.claude/worktrees`, where Claude's worktree agents work, do not ask. A hook script that your settings name in another place stays a gap: an edit of it runs outside the sandbox at the next hook.
- A Codex agent ([subagents.md](subagents.md#codex-agents)) runs in Codex's own sandbox, which lets it write files in the project that Claude's edits ask for, such as `.envrc`, `.npmrc` and `.claude/settings.json`. anvim asks before a Codex run that may write: "writes outside the sandbox, also files that run code". Default and accept edits mode ask there anyway, and it stays one prompt. A read-only run and plan mode do not ask. This call never goes back to Claude first, because a Codex run that writes has no way inside the sandbox.

A model sometimes takes one of these ways by accident, when a way inside the sandbox exists. So anvim does not ask at the first such call of Claude or of each subagent. It sends the call back to Claude with a hint. The hint says that anvim has not asked you yet, and it names a way that needs no prompt. It also says that Claude can send the same call again to get your answer. After that one send-back, each such call of that agent asks you. The transcript shows the call's result as "Sent back to Claude: runs outside the sandbox". An agent's log names the agent. `/clear` starts over for Claude. anvim writes each send-back, and each later prompt of that agent, to `~/.local/state/anvim/anvim.log`. These lines start with `send-back:`.

`--no-sandbox` turns these prompts off too.

### Without a sandbox

On Linux, the sandbox needs `bwrap` (from bubblewrap) and `socat`. Without them, anvim warns, commands run without the sandbox, and anvim runs in default mode, so Claude asks before it runs a tool. The same happens when Claude Code finds that the sandbox cannot start. `--no-sandbox` also starts anvim in default mode, without a warning. A mode that you chose with `--mode`, `ANVIM_MODE` or your own spec stays: with `--mode bypassPermissions`, commands then run anywhere without asking. `--dangerously-skip-permissions` is short for `--no-sandbox --mode bypassPermissions`: Claude runs every tool anywhere, and only its questions and plans wait for you.

`:checkhealth anvim` says whether the sandbox is on, and which mode anvim starts in and why. `anvim --no-sandbox`, or `ANVIM_SANDBOX=0`, turns it off, also when a settings file turns it on. A spec of your own can set the anvim plugin's `sandbox` option to `false` too.

### Caches and other dirs

Some tools write to caches outside the project, and fail in the sandbox. anvim lets the sandbox write the caches of npm (`~/.npm`, also for `npx`), bun install (`~/.bun/install/cache`) and go build (`~/Library/Caches/go-build` on macOS, `~/.cache/go-build` on Linux). In bypass mode, Claude's edits there do not ask either. These caches hold code that runs later outside the sandbox, such as the packages in `~/.npm/_npx`, so a command in the sandbox can change what runs outside it. That fits the sandbox's job: it catches accidents, not an agent that tries to get out.

For another tool, add its dir to your own Claude Code settings, `~/.claude/settings.json`. These lists add to anvim's sandbox options:

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": ["~/.cache/<tool>"]
    }
  }
}
```

Each entry lets every sandboxed command write there. Two more keys in `sandbox` make other tools work on macOS, at a cost:

- `"network": { "allowUnixSockets": ["<path>"] }`, with the real path of `$SSH_AUTH_SOCK`, such as `/private/var/run/com.apple.launchd.../Listeners`, makes `ssh-add` work. Every sandboxed command can then sign with your SSH keys, and the path changes when you log in again. git over ssh works without it.
- `"enableWeakerNetworkIsolation": true` makes `gh` and `pip` work, because they check TLS certificates through the system's trust service. The Agent SDK's docs say that this opens a possible path for data to leave the machine.
