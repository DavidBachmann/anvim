// The plan usage that the statusline shows. The end of each turn fetches it.
// A long turn also fetches it every five minutes, and a timer fetches it
// after a window resets.
import type { Query, SDKControlGetUsageResponse, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";

const EVERY_MS = 5 * 60_000;

export function limitsEvent(u: SDKControlGetUsageResponse): Event {
  const session = u.rate_limits?.five_hour?.utilization;
  const week = u.rate_limits?.seven_day?.utilization;
  return {
    type: "limits",
    session: session == null ? undefined : Math.round(session),
    week: week == null ? undefined : Math.round(week),
  };
}

// The time until a minute after the first of the two windows resets. The
// minute gives the usage endpoint time to start the new window.
export function limitsResetDelay(u: SDKControlGetUsageResponse, now = Date.now()): number | undefined {
  const resets = [u.rate_limits?.five_hour, u.rate_limits?.seven_day]
    .map((w) => Date.parse(w?.resets_at ?? ""))
    .filter((t) => t > now);
  return resets.length ? Math.min(...resets) - now + 60_000 : undefined;
}

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
