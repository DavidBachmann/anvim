import { describe, expect, mock, test } from "bun:test";
import * as sdk from "@anthropic-ai/claude-agent-sdk";
import type { Options } from "@anthropic-ai/claude-agent-sdk";

// A session that answers the control requests and never sends a message, so
// the sidecar's run never ends. Its effort works as in Claude Code: a level
// stays over a model switch, and null goes to the model's own level.
const ids: Record<string, string> = { haiku: "claude-haiku-5-5", sonnet: "claude-sonnet-5-5", opus: "claude-opus-5-5" };
const started: Options[] = [];
const calls: [string, unknown][] = [];
const applied = { model: "claude-haiku-5-5", effort: "medium" as string | null };
let sources: unknown[] = [];
const session = {
  async *[Symbol.asyncIterator]() {
    await new Promise(() => {});
  },
  supportedCommands: async () => [],
  supportedModels: async () => [
    {
      value: "haiku",
      displayName: "Haiku 5.5",
      description: "Fastest",
      resolvedModel: "claude-haiku-5-5",
      supportsEffort: true,
      supportedEffortLevels: ["low", "medium", "high"],
    },
    { value: "claude-haiku-4-5", displayName: "Haiku 4.5", description: "Older" },
  ],
  getSettings: async () => ({ applied: { ...applied }, sources }),
  setModel: async (model?: string) => {
    calls.push(["setModel", model]);
    applied.model = ids[model ?? ""] ?? model ?? "claude-opus-5-5";
  },
  applyFlagSettings: async (settings: { effortLevel?: string | null }) => {
    calls.push(["effortLevel", settings.effortLevel]);
    applied.effort = settings.effortLevel ?? "medium";
  },
};
// A resumed session's history waits until the test opens the gate.
let open!: () => void;
const gate = new Promise<void>((resolve) => (open = resolve));
mock.module("@anthropic-ai/claude-agent-sdk", () => ({
  ...sdk,
  query: ({ options }: { options: Options }) => {
    started.push(options);
    return session;
  },
  getSessionInfo: async () => {
    await gate;
    return undefined;
  },
}));
const { handle, settingsEffort } = await import("./main");

// The events that the sidecar writes while fn runs.
async function emitted(fn: () => Promise<unknown>, until: (events: any[]) => boolean): Promise<any[]> {
  const events: any[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => {
    for (const line of String(chunk).split("\n")) if (line.startsWith("{")) events.push(JSON.parse(line));
    return true;
  }) as typeof process.stdout.write;
  try {
    await fn();
    for (let i = 0; i < 100 && !until(events); i++) await Bun.sleep(5);
  } finally {
    process.stdout.write = write;
  }
  return events;
}

const efforts = (events: any[]) => events.filter((e) => e.type === "effort").map((e) => e.level);

describe("the sidecar's session", () => {
  test("model and effort changes wait for a resumed session, and then run in order", async () => {
    const events = await emitted(
      async () => {
        await handle({ type: "start", cwd: "/tmp", model: "haiku", resume: "s1" });
        const changes = [handle({ type: "set_model", model: "sonnet" }), handle({ type: "set_effort", effort: "low" })];
        await Bun.sleep(20);
        expect([started.length, calls.length]).toEqual([0, 0]);
        open();
        await Promise.all(changes);
      },
      (evs) => evs.some((e) => e.type === "models"),
    );
    expect(started.map((o) => [o.model, o.effort, o.resume])).toEqual([["haiku", undefined, undefined]]);
    expect(calls).toEqual([
      ["setModel", "sonnet"],
      ["effortLevel", "low"],
    ]);
    // The start's effort, then the one after each change.
    expect(efforts(events)).toEqual(["medium", "medium", "low"]);
    expect(events.find((e) => e.type === "models")?.models).toEqual([
      {
        value: "haiku",
        name: "Haiku 5.5",
        description: "Fastest",
        resolved: "claude-haiku-5-5",
        effort_levels: ["low", "medium", "high"],
      },
      { value: "claude-haiku-4-5", name: "Haiku 4.5", description: "Older" },
    ]);
  });

  test("the default is the effort of a new session, and it follows a model switch", async () => {
    sources = [
      {
        source: "userSettings",
        settings: { effortLevel: "max", modelSettings: { "claude-opus-5-5": { effortLevel: "xhigh" } } },
      },
    ];
    calls.length = 0;
    const events = await emitted(
      async () => {
        // A chosen level stays over a switch.
        await handle({ type: "set_model", model: "opus" });
        // Opus takes its level from the settings.
        await handle({ type: "set_effort", effort: null });
        // The session inherited medium on Haiku at start, which counts over the settings.
        await handle({ type: "set_model", model: "haiku" });
        await handle({ type: "set_effort", effort: "high" });
        await handle({ type: "set_model", model: "opus" });
      },
      (evs) => efforts(evs).length === 5,
    );
    expect(calls).toEqual([
      ["setModel", "opus"],
      ["effortLevel", "xhigh"],
      ["setModel", "haiku"],
      ["effortLevel", "medium"],
      ["effortLevel", "high"],
      ["setModel", "opus"],
    ]);
    expect(efforts(events)).toEqual(["low", "xhigh", "medium", "high", "high"]);
  });

  test("the settings' effort for a model comes from the highest file that names one", () => {
    const user = { effortLevel: "xhigh", modelSettings: { "claude-opus-5-5-20261001": { effortLevel: "high" } } };
    const answer = (...rest: unknown[]) => ({ sources: [{ source: "userSettings", settings: user }, ...rest] as any });
    // The user's own top-level level does not count.
    expect(settingsEffort(answer(), "claude-haiku-5-5")).toBeNull();
    expect(settingsEffort(answer(), "claude-opus-5-5")).toBe("high");
    expect(settingsEffort(answer(), "claude-opus-5-5[1m]")).toBe("high");
    const project = { source: "projectSettings", settings: { modelSettings: { "claude-haiku-5-5": { effortLevel: "low" } } } };
    expect(settingsEffort(answer(project), "claude-haiku-5-5")).toBe("low");
    // A top-level level above the user's file counts for every model, and the
    // flag settings are anvim's own.
    const local = { source: "localSettings", settings: { effortLevel: "medium" } };
    const flag = { source: "flagSettings", settings: { effortLevel: "max" } };
    expect(settingsEffort(answer(project, local, flag), "claude-haiku-5-5")).toBe("medium");
    expect(settingsEffort(answer(project, local, flag), "claude-opus-5-5")).toBe("medium");
  });
});
