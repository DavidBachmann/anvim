import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

// Starts the replay of these events, 10 ms apart, and collects the types of
// the events that it prints.
function replay(events: object[]) {
  const dir = mkdtempSync(join(tmpdir(), "anvim-replay-"));
  dirs.push(dir);
  const file = join(dir, "rec.jsonl");
  writeFileSync(file, events.map((ev, i) => `${1000 + i * 10} ${JSON.stringify(ev)}\n`).join(""));
  const proc = Bun.spawn(["bun", join(import.meta.dir, "replay.ts"), file, "10"], { stdin: "pipe", stdout: "pipe" });
  const types: string[] = [];
  void (async () => {
    let buf = "";
    for await (const chunk of proc.stdout) {
      buf += new TextDecoder().decode(chunk);
      const lines = buf.split("\n");
      buf = lines.pop()!;
      for (const line of lines) types.push(JSON.parse(line).type);
    }
  })();
  const send = (cmd: object) => {
    proc.stdin.write(JSON.stringify(cmd) + "\n");
    proc.stdin.flush();
  };
  return { types, send, proc };
}

async function until(fn: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !fn(); i++) await Bun.sleep(20);
}

test("a prompt plays its turn with the effort and context usage after it", async () => {
  const turn = [{ type: "turn_start" }, { type: "text_delta", text: "Hi" }, { type: "turn_end" }];
  const after = [{ type: "effort", level: "medium" }, { type: "context", percent: 5 }];
  const { types, send, proc } = replay([{ type: "init" }, ...turn, ...after, ...turn, ...after]);
  send({ type: "start" });
  send({ type: "prompt", text: "one" });
  await until(() => types.length >= 6);
  // The next turn waits for its prompt.
  await Bun.sleep(200);
  expect(types).toEqual(["init", "turn_start", "text_delta", "turn_end", "effort", "context"]);
  send({ type: "prompt", text: "two" });
  await until(() => types.length >= 11);
  expect(types.slice(6)).toEqual(["turn_start", "text_delta", "turn_end", "effort", "context"]);
  proc.stdin.end();
  await proc.exited;
});
