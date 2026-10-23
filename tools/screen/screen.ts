// Embeds anvim, attaches as a UI, and records exactly what Nvim draws: text,
// highlight groups and colors, and the timing of every redraw.
//
// Usage: bun screen.ts [--cwd dir] [--size 200x50] [--replay file] [--model m] [--effort e] [--mode m] [--out dir] [--xdg dir] -- step...
// anvim's state, cache, data and config dirs go in --xdg, by default a new temp
// dir. Its plugins come from .tests/anvim, which scripts/test-deps fills on the
// first run. The tool prints the path of anvim's log at the end.
// Steps:
//   wait:<ms>          sleep
//   waitfor:<text>     wait until the screen shows text (20 s timeout)
//   keys:<keys>        nvim_input, e.g. keys:hello<CR>
//   lua:<code>         nvim_exec_lua
//   resize:<WxH>       resize the UI, e.g. resize:160x40
//   mouse:<b>,<a>,<r>,<c>  nvim_input_mouse at 0-based row and col, e.g. mouse:left,press,5,100
//   snap:<name>        write <name>.txt, <name>.hl.txt, <name>.svg and <name>.png (via headless Chrome)
//   record:<ms>        log every flush that changes cells or moves the cursor for ms to frames.log,
//                      with a timing summary. Use lua:vim.defer_fn(...) to act while it records.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { root, Ui } from "./ui.ts";

const args = process.argv.slice(2);
const split = args.indexOf("--");
const flags = split === -1 ? args : args.slice(0, split);
const steps = split === -1 ? [] : args.slice(split + 1);
const flag = (name: string) => {
  const i = flags.indexOf(name);
  return i === -1 ? undefined : flags[i + 1];
};
const [cols, rows] = (flag("--size") ?? "200x50").split("x").map(Number) as [number, number];
const out = resolve(flag("--out") ?? ".");
mkdirSync(out, { recursive: true });

const env: Record<string, string> = {};
if (flag("--replay")) env.ANVIM_REPLAY = resolve(flag("--replay")!);
if (flag("--model")) env.ANVIM_MODEL = flag("--model")!;
if (flag("--mode")) env.ANVIM_MODE = flag("--mode")!;
if (flag("--effort")) env.ANVIM_EFFORT = flag("--effort")!;

const xdg = resolve(flag("--xdg") ?? mkdtempSync(join(tmpdir(), "anvim-screen-")));
// The plugins come from .tests/anvim, as in the UI tests.
if (Bun.spawnSync([join(root, "scripts/test-deps")], { stdout: "inherit", stderr: "inherit" }).exitCode !== 0) process.exit(1);
const ui = await Ui.start({ cwd: resolve(flag("--cwd") ?? "."), cols, rows, xdg, env });

async function record(ms: number) {
  const start = performance.now();
  const mark = ui.mark();
  await Bun.sleep(ms);
  const log: string[] = [];
  const gaps: number[] = [];
  let last = start;
  let prevCursor = `${ui.cursor.row},${ui.cursor.col}`;
  for (const f of ui.frames(mark)) {
    const at = `${f.cursor.row},${f.cursor.col}`;
    if (!f.cells && at === prevCursor) continue;
    prevCursor = at;
    gaps.push(f.t - last);
    last = f.t;
    log.push(`+${Math.round(f.t - start)}ms cells=${f.cells} rows=${f.changed.join(",")} cursor=${at}`);
    for (const r of f.changed.slice(0, 4)) log.push(`    ${r}: ${f.lines[r]!.trimEnd().slice(0, 160)}`);
  }
  const sorted = [...gaps].sort((a, b) => a - b);
  const pct = (p: number) => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0);
  const summary = `frames=${gaps.length} median_gap=${pct(0.5)}ms p95_gap=${pct(0.95)}ms max_gap=${pct(1)}ms`;
  writeFileSync(join(out, "frames.log"), summary + "\n" + log.join("\n") + "\n");
  console.log(summary);
}

async function main() {
  for (const step of steps) {
    const colon = step.indexOf(":");
    const kind = step.slice(0, colon);
    const arg = step.slice(colon + 1);
    if (kind === "wait") await Bun.sleep(Number(arg));
    else if (kind === "keys") await ui.input(arg);
    else if (kind === "lua") await ui.exec_lua(arg);
    else if (kind === "resize") {
      const [w, h] = arg.split("x").map(Number) as [number, number];
      await ui.resize(w, h);
    } else if (kind === "mouse") {
      const [button, action, row, col] = arg.split(",");
      await ui.inputMouse(button!, action!, Number(row), Number(col));
    } else if (kind === "snap") await ui.snap(out, arg);
    else if (kind === "record") await record(Number(arg));
    else if (kind === "waitfor") await ui.waitFor(arg, 20000);
    else throw new Error(`unknown step ${step}`);
  }
  console.log(`flushes=${ui.mark()} out=${out}`);
}

let failed = false;
try {
  await main();
} catch (err) {
  console.error(err);
  failed = true;
}
await ui.close();
process.stderr.write(ui.stderr);
console.log(`log=${join(xdg, "state", "anvim", "anvim.log")}`);
process.exit(failed ? 1 : 0);
