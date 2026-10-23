// Stands in for main.ts and replays a file that ANVIM_RECORD wrote, with the
// original timing. Each prompt command plays the next recorded turn.
// Usage: bun src/replay.ts <recording> [speed]
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";

const [file, speedArg] = process.argv.slice(2);
if (!file) {
  process.stderr.write("usage: replay.ts <recording> [speed]\n");
  process.exit(2);
}
const speed = Number(speedArg ?? 1) || 1;

const frames = readFileSync(file, "utf8")
  .split("\n")
  .filter(Boolean)
  .flatMap((line) => {
    const space = line.indexOf(" ");
    const text = line.slice(space + 1);
    try {
      return [{ at: Number(line.slice(0, space)), line: text, ev: JSON.parse(text) }];
    } catch {
      process.stderr.write(`replay: skipped a line that is not JSON: ${line.slice(0, 200)}\n`);
      return [];
    }
  });

let cursor = 0;
let playing: Promise<void> = Promise.resolve();
// Background agents work on after their turn, and each one's end starts a
// turn of its own, so a prompt plays on until none runs.
const background = new Set<string>();

// The effort and context usage that the sidecar sends after a turn ends
// belong to it.
const AFTER_TURN = new Set(["effort", "context"]);

// Plays frames up to the first one whose type is `until`. Without inclusive,
// it stops before that frame. With inclusive, it plays that frame and the
// AFTER_TURN frames after it. While a background agent runs, it plays on to
// the next `until` frame.
async function play(until: string | null, inclusive: boolean): Promise<void> {
  let last: number | null = null;
  let ended = false;
  while (cursor < frames.length) {
    const frame = frames[cursor]!;
    const ev = frame.ev;
    if (ended && !AFTER_TURN.has(ev.type)) return;
    if (ev.type === until && !inclusive) return;
    if (last !== null) await Bun.sleep(Math.max(0, frame.at - last) / speed);
    last = frame.at;
    process.stdout.write(frame.line + "\n");
    cursor++;
    if (ev.type === "agent_start" && ev.background) background.add(ev.agent_id);
    if (ev.type === "agent_end") background.delete(ev.agent_id);
    if (ev.type === until) ended = background.size === 0;
  }
}

createInterface({ input: process.stdin })
  .on("line", (line) => {
    const cmd = JSON.parse(line);
    if (cmd.type === "start") playing = playing.then(() => play("turn_start", false));
    else if (cmd.type === "prompt") playing = playing.then(() => play("turn_end", true));
  })
  .on("close", () => process.exit(0));
