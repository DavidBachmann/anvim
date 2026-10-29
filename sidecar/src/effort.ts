// The session's effort level, as the statusline and the effort picker show it.
import type { Query } from "@anthropic-ai/claude-agent-sdk";
import type { EffortLevel, Event } from "./protocol";
import type { GuardSettings } from "./sandbox";

// What getSettings() answers. The SDK has the method, but not in its types.
export type SettingsAnswer = GuardSettings & {
  sources?: { source: string; settings?: Record<string, any> | null }[];
  applied?: { model?: string; effort?: EffortLevel | null };
};

export function getSettings(q: Query): Promise<SettingsAnswer> {
  return (q as unknown as { getSettings(): Promise<SettingsAnswer> }).getSettings();
}

// claude-opus-5-5[1m] and claude-opus-5-5-20261001 are claude-opus-5-5.
function canonical(model: string): string {
  return model.replace(/\[1m\]$/i, "").replace(/-\d{8}$/, "");
}

// The level that a new session takes from the settings files for a model:
// the model's modelSettings entry, or a file's top-level effortLevel, from
// the highest file that has either. Claude Code applies the user's own
// top-level effortLevel only to some older models, so it does not count here.
// The flag settings are anvim's own. null leaves the model's own level.
export function settingsEffort(answer: SettingsAnswer, model: string): EffortLevel | null {
  const name = canonical(model);
  for (const { source, settings } of [...(answer.sources ?? [])].reverse()) {
    if (source === "flagSettings" || !settings) continue;
    const entries = Object.entries(settings.modelSettings ?? {}) as [string, { effortLevel?: EffortLevel }][];
    const own = entries.find(([key]) => key === name) ?? entries.find(([key]) => canonical(key) === name);
    const level = own?.[1]?.effortLevel ?? (source === "userSettings" ? undefined : settings.effortLevel);
    if (level) return level;
  }
  return null;
}

// A session that started without an effort inherits it: Claude Code takes it
// from the settings for each model, as in a new session. A level from
// set_effort ends that, and the flag settings cannot bring it back. After
// set_effort null, a model switch applies the settings' level for the new
// model, so the default follows the model as an inherited effort does.
export class Effort {
  private state: "inherited" | "following" | "fixed" = "fixed";
  // The levels that the session inherited, by model. They are Claude Code's own
  // answer, which settingsEffort() only comes close to.
  private inherited = new Map<string, EffortLevel | null>();

  constructor(private emit: (ev: Event) => void) {}

  start(level: EffortLevel | undefined): void {
    this.state = level ? "fixed" : "inherited";
  }

  async report(q: Query): Promise<void> {
    try {
      const { applied } = await getSettings(q);
      const level = applied?.effort ?? null;
      if (this.state === "inherited" && applied?.model) this.inherited.set(applied.model, level);
      this.emit({ type: "effort", level });
    } catch {
      // Without get_settings, the statusline shows no effort.
    }
  }

  async setModel(q: Query, model: string | undefined): Promise<void> {
    await q.setModel(model);
    if (this.state === "following") await q.applyFlagSettings({ effortLevel: await this.defaultLevel(q) });
    await this.report(q);
  }

  async set(q: Query, level: EffortLevel | null): Promise<void> {
    // An inherited effort is the default already.
    if (level !== null || this.state !== "inherited") {
      this.state = level === null ? "following" : "fixed";
      // The flag layer, so the effort lasts for this session only, and no
      // settings file changes.
      await q.applyFlagSettings({ effortLevel: level ?? (await this.defaultLevel(q)) });
    }
    await this.report(q);
  }

  private async defaultLevel(q: Query): Promise<EffortLevel | null> {
    const answer = await getSettings(q);
    const model = answer.applied?.model;
    if (!model) return null;
    return this.inherited.has(model) ? this.inherited.get(model)! : settingsEffort(answer, model);
  }
}
