// The preview handshake. A PreToolUse hook on the edit tools holds each edit
// until the plugin answers preview_done, so the file never changes ahead of
// the view. A preview that takes too long lets the edit go anyway.
import type { HookCallback, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";

export const TIMEOUT_MS = {
  // The main agent's input streams, so its preview has nearly caught up when the hook fires.
  main: 3000,
  // A subagent's edit arrives whole. The plugin types it in at most 2 s.
  agent: 5000,
};

export class PreviewBridge {
  private pending = new Map<number, () => void>();
  private next = 1;

  constructor(
    private emit: (ev: Event) => void,
    private timeoutMs = TIMEOUT_MS,
  ) {}

  hook: HookCallback = async (input, toolUseID, { signal }) => {
    if (!toolUseID) return {};
    const { agent_id, tool_name, tool_input } = input as PreToolUseHookInput;
    const req = this.next++;
    await new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer);
        signal.removeEventListener("abort", done);
        this.pending.delete(req);
        resolve();
      };
      const timer = setTimeout(done, agent_id ? this.timeoutMs.agent : this.timeoutMs.main);
      signal.addEventListener("abort", done, { once: true });
      this.pending.set(req, done);
      this.emit({
        type: "await_preview",
        req,
        tool_use_id: toolUseID,
        ...(agent_id ? { agent_id, name: tool_name, input: (tool_input ?? {}) as Record<string, unknown> } : {}),
      });
    });
    return {};
  };

  done(req: number): void {
    this.pending.get(req)?.();
  }

  get waiting(): number {
    return this.pending.size;
  }
}
