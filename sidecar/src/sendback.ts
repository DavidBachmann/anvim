// The send-back: the first call of each agent that anvim's sandbox guards
// would ask about goes back to Claude with a hint, and the user sees no
// prompt. A model sometimes picks such a call when a sandboxed way exists.
// After that one send-back, each guarded call of the agent asks the user.
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { REASONS } from "./sandbox";

const OUTSIDE = REASONS.outside("");

// What Claude reads in place of the tool's result. Each hint says that the
// user was not asked yet, because a model can read a plain deny as the user's
// no and give up.
export function hint(reason: string, tmpDir: string): string {
  const again = "send the same call again, and anvim asks the user.";
  const skip = "If the task does not need this change, go on without it, or tell the user what to change.";
  if (reason === REASONS.escape) {
    return `anvim held this command back and has not asked the user yet. It would run outside the sandbox. In the sandbox, Bash can write in the project and in $TMPDIR. It can also write in the npm, bun and go caches, and in dirs that the settings allow. Point other outputs to $TMPDIR, for example XDG_CACHE_HOME=$TMPDIR/cache. If no sandboxed way works, or the user asked for exactly this, ${again}`;
  }
  if (reason === REASONS.excluded) {
    return `anvim held this command back and has not asked the user yet. The settings exclude this command from the sandbox, so it can run outside the sandbox. If another command can do the job inside the sandbox, use it. If no other command works, or the user asked for exactly this, ${again}`;
  }
  if (reason === REASONS.settings) {
    return `anvim held this edit back and has not asked the user yet. The file holds Claude Code's settings for this project, and they can widen the sandbox. ${skip} If the user asked for this change, ${again}`;
  }
  if (reason === REASONS.config) {
    return `anvim held this edit back and has not asked the user yet. The file configures tools that run outside the sandbox, such as git hooks or shell startup files. ${skip} If the user asked for this change, ${again}`;
  }
  if (reason.startsWith(OUTSIDE)) {
    return `anvim held this edit back and has not asked the user yet. The file is outside the project and the dirs that anvim trusts. Put scratch files in the project or in the sandbox's temp dir, ${tmpDir}. If the user asked for this file, ${again}`;
  }
  return `anvim held this call back and has not asked the user yet. It ${reason}. If the user asked for exactly this, ${again}`;
}

export type GuardedCall = {
  tool: string;
  input: Record<string, unknown>;
  reason: string;
  agentID?: string;
};

// The command of a Bash call, or the path of an edit.
function target(call: GuardedCall): string {
  const { command, file_path, notebook_path } = call.input;
  const text = [command, file_path, notebook_path].find((v) => typeof v === "string");
  return typeof text === "string" ? text : "";
}

export type SendBackOptions = {
  tmpDir: string;
  // Lines for anvim.log, through the sidecar's stderr.
  log?: (line: string) => void;
};

export class SendBack {
  // The sent-back call of each agent, by agent_id, "" for the main agent.
  private sent = new Map<string, { tool: string; target: string }>();
  private log: (line: string) => void;

  constructor(private opts: SendBackOptions) {
    this.log = opts.log ?? ((line) => process.stderr.write(line + "\n"));
  }

  // The hint when this guarded call goes back to Claude, or undefined when
  // the user is asked. Each call must come here once.
  decide(call: GuardedCall): string | undefined {
    // A Codex run that writes files has no way inside the sandbox.
    if (call.reason === REASONS.codex) return undefined;
    const key = call.agentID ?? "";
    const what = target(call);
    const line = `${call.agentID ?? "main"} ${call.tool} ${call.reason}: ${what.replace(/\n/g, "\\n").slice(0, 200)}`;
    const before = this.sent.get(key);
    if (before) {
      const same = before.tool === call.tool && before.target === what;
      this.log(`send-back: asked ${line} (${same ? "same call" : "other call"})`);
      return undefined;
    }
    this.sent.set(key, { tool: call.tool, target: what });
    this.log(`send-back: ${line}`);
    return hint(call.reason, this.opts.tmpDir);
  }

  // /clear starts a new conversation for the main agent. A background agent
  // that runs on keeps its context, and with it the hint, and new agents get
  // new ids. A compaction keeps the conversation.
  message(msg: SDKMessage): void {
    if (msg.type === "conversation_reset") this.sent.delete("");
  }
}
