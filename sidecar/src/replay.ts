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
  .map((line) => {
    const space = line.indexOf(" ");
    return { at: Number(line.slice(0, space)), line: line.slice(space + 1) };
  });

let cursor = 0;
let playing: Promise<void> = Promise.resolve();

function typeOf(line: string): string {
  return JSON.parse(line).type;
}

// Plays frames until (and including) the first one whose type is `until`.
async function play(until: string | null, inclusive: boolean): Promise<void> {
  let last: number | null = null;
  while (cursor < frames.length) {
    const frame = frames[cursor]!;
    const type = typeOf(frame.line);
    if (type === until && !inclusive) return;
    if (last !== null) await Bun.sleep(Math.max(0, frame.at - last) / speed);
    last = frame.at;
    process.stdout.write(frame.line + "\n");
    cursor++;
    if (type === until) return;
  }
}

createInterface({ input: process.stdin })
  .on("line", (line) => {
    const cmd = JSON.parse(line);
    if (cmd.type === "start") playing = playing.then(() => play("turn_start", false));
    else if (cmd.type === "prompt") playing = playing.then(() => play("turn_end", true));
  })
  .on("close", () => process.exit(0));
