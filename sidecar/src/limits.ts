// The plan usage that the statusline shows. The end of each turn fetches it.
// A long turn also fetches it every five minutes, and a timer fetches it
// after a window resets.
import type { Query, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import { limitsEvent, limitsResetDelay } from "./translate";

const EVERY_MS = 5 * 60_000;

export class Limits {
  private at = 0;
  private reset: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private emit: (ev: Event) => void,
    private q: Query,
  ) {}

  // Each SDK message of the session.
  message(msg: SDKMessage): void {
    if (msg.type === "result" || Date.now() - this.at > EVERY_MS) void this.report();
  }

  // skipBehaviors leaves out the scan of local transcripts that /usage needs.
  async report(): Promise<void> {
    this.at = Date.now();
    clearTimeout(this.reset);
    try {
      const usage = await this.q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
      this.emit(limitsEvent(usage));
      const delay = limitsResetDelay(usage);
      if (delay !== undefined) this.reset = setTimeout(() => void this.report(), delay).unref();
    } catch {
      // The plan usage is a nicety. The next turn tries again.
    }
  }
}
