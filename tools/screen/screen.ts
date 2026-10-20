// Embeds anvim, attaches as a UI, and records exactly what Nvim draws: text,
// highlight groups and colors, and the timing of every redraw.
//
// Usage: bun screen.ts [--cwd dir] [--size 200x50] [--replay file] [--model m] [--mode m] [--out dir] -- step...
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
import { decodeMultiStream, encode } from "@msgpack/msgpack";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Attr = {
  foreground?: number;
  background?: number;
  special?: number;
  reverse?: boolean;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  undercurl?: boolean;
  strikethrough?: boolean;
};
type Cell = { text: string; hl: number };

const root = resolve(import.meta.dir, "../..");
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
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

const env: Record<string, string> = { ...(process.env as Record<string, string>), NVIM_APPNAME: "anvim" };
if (flag("--replay")) env.ANVIM_REPLAY = resolve(flag("--replay")!);
if (flag("--model")) env.ANVIM_MODEL = flag("--model")!;
if (flag("--mode")) env.ANVIM_MODE = flag("--mode")!;

const nvim = Bun.spawn(["nvim", "--embed", "-u", join(root, "init.lua")], {
  cwd: resolve(flag("--cwd") ?? "."),
  env,
  stdin: "pipe",
  stdout: "pipe",
  stderr: "inherit",
});

// msgpack-rpc
let nextId = 1;
const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: unknown) => void }>();
function request(method: string, params: unknown[]): Promise<unknown> {
  const id = nextId++;
  nvim.stdin.write(encode([0, id, method, params]));
  nvim.stdin.flush();
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

// UI state
let grid: Cell[][] = [];
const attrs = new Map<number, { rgb: Attr; names: string }>();
let defaults = { fg: 0xe0def4, bg: 0x191724 };
let cursor = { row: 0, col: 0 };
let flushes = 0;
let onFlush: (() => void) | null = null;

function resize(w: number, h: number) {
  grid = Array.from({ length: h }, () => Array.from({ length: w }, () => ({ text: " ", hl: 0 })));
}

function handle(name: string, a: any[]) {
  switch (name) {
    case "grid_resize":
      resize(a[1], a[2]);
      break;
    case "default_colors_set":
      defaults = { fg: a[0] >= 0 ? a[0] : defaults.fg, bg: a[1] >= 0 ? a[1] : defaults.bg };
      break;
    case "hl_attr_define": {
      const info = (a[3] ?? []) as { hi_name?: string; ui_name?: string }[];
      const names = info.map((i) => i.hi_name ?? i.ui_name).filter(Boolean).join("+");
      attrs.set(a[0], { rgb: a[1], names });
      break;
    }
    case "grid_line": {
      const [, row, colStart, cells] = a;
      let col = colStart;
      let hl = 0;
      for (const cell of cells as any[]) {
        const [text, id, repeat] = cell;
        if (id !== undefined) hl = id;
        for (let i = 0; i < (repeat ?? 1); i++) {
          if (grid[row]?.[col]) grid[row][col] = { text, hl };
          col++;
        }
      }
      break;
    }
    case "grid_clear":
      resize(grid[0]?.length ?? cols, grid.length || rows);
      break;
    case "grid_cursor_goto":
      cursor = { row: a[1], col: a[2] };
      break;
    case "grid_scroll": {
      const [, top, bot, left, right, n] = a;
      const copy = grid.map((r) => r.map((c) => ({ ...c })));
      for (let r = top; r < bot; r++) {
        const from = r + n;
        if (from < top || from >= bot) continue;
        for (let c = left; c < right; c++) grid[r]![c] = copy[from]![c]!;
      }
      break;
    }
    case "flush":
      flushes++;
      onFlush?.();
      break;
  }
}

(async () => {
  for await (const msg of decodeMultiStream(nvim.stdout)) {
    const m = msg as any[];
    if (m[0] === 1) {
      const p = pending.get(m[1]);
      pending.delete(m[1]);
      if (m[2]) p?.reject(m[2]);
      else p?.resolve(m[3]);
    } else if (m[0] === 2 && m[1] === "redraw") {
      for (const [name, ...calls] of m[2] as any[][]) for (const call of calls) handle(name as string, call);
    } else if (m[0] === 0) {
      nvim.stdin.write(encode([1, m[1], null, null]));
    }
  }
})();

const rowText = (r: Cell[]) => r.map((c) => c.text).join("");
const screenText = () => grid.map(rowText).join("\n");

function hlDump(): string {
  const lines: string[] = [];
  grid.forEach((row, r) => {
    let start = 0;
    for (let c = 1; c <= row.length; c++) {
      if (c < row.length && row[c]!.hl === row[start]!.hl) continue;
      const names = attrs.get(row[start]!.hl)?.names;
      const text = row.slice(start, c).map((x) => x.text).join("");
      if (names && text.trim()) lines.push(`r${r} c${start}-${c - 1} ${names}: ${text.trimEnd()}`);
      start = c;
    }
  });
  return lines.join("\n") + "\n";
}

const hex = (n: number) => "#" + n.toString(16).padStart(6, "0");
const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function svg(): string {
  const cw = 9.6;
  const ch = 20;
  const w = Math.ceil((grid[0]?.length ?? cols) * cw);
  const h = grid.length * ch;
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" font-family="JetBrainsMono Nerd Font, Menlo, monospace" font-size="16">`,
    `<rect width="${w}" height="${h}" fill="${hex(defaults.bg)}"/>`,
  ];
  grid.forEach((row, r) => {
    let start = 0;
    for (let c = 1; c <= row.length; c++) {
      if (c < row.length && row[c]!.hl === row[start]!.hl) continue;
      const a = attrs.get(row[start]!.hl)?.rgb ?? {};
      let fg = a.foreground ?? defaults.fg;
      let bg = a.background ?? defaults.bg;
      if (a.reverse) [fg, bg] = [bg, fg];
      const x = start * cw;
      const y = r * ch;
      const n = c - start;
      if (bg !== defaults.bg) parts.push(`<rect x="${x}" y="${y}" width="${n * cw}" height="${ch}" fill="${hex(bg)}"/>`);
      const text = row.slice(start, c).map((x) => x.text).join("");
      if (text.trim()) {
        const deco = [a.underline || a.undercurl ? "underline" : "", a.strikethrough ? "line-through" : ""].join(" ").trim();
        parts.push(
          `<text x="${x}" y="${y + 15}" fill="${hex(fg)}" xml:space="preserve" textLength="${n * cw}" lengthAdjust="spacingAndGlyphs"` +
            (a.bold ? ` font-weight="bold"` : "") +
            (a.italic ? ` font-style="italic"` : "") +
            (deco ? ` text-decoration="${deco}"` : "") +
            `>${xml(text)}</text>`,
        );
      }
      start = c;
    }
  });
  parts.push(
    `<rect x="${cursor.col * cw}" y="${cursor.row * ch}" width="${cw}" height="${ch}" fill="none" stroke="${hex(defaults.fg)}"/>`,
    "</svg>",
  );
  return parts.join("\n");
}

function snap(name: string) {
  writeFileSync(join(out, `${name}.txt`), screenText() + "\n");
  writeFileSync(join(out, `${name}.hl.txt`), hlDump());
  const file = join(out, `${name}.svg`);
  writeFileSync(file, svg());
  const w = Math.ceil((grid[0]?.length ?? cols) * 9.6);
  const h = grid.length * 20;
  Bun.spawnSync(
    [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", `--screenshot=${join(out, `${name}.png`)}`, `--window-size=${w},${h}`, `file://${file}`],
    { stdout: "ignore", stderr: "ignore" },
  );
}

async function record(ms: number) {
  const log: string[] = [];
  const start = performance.now();
  let prev = grid.map((r) => r.map((c) => c.text + c.hl));
  let prevCursor = `${cursor.row},${cursor.col}`;
  let last = start;
  const gaps: number[] = [];
  onFlush = () => {
    const now = performance.now();
    const changed: number[] = [];
    let cells = 0;
    grid.forEach((row, r) => {
      let rowChanged = false;
      row.forEach((c, i) => {
        if (prev[r]?.[i] !== c.text + c.hl) {
          cells++;
          rowChanged = true;
        }
      });
      if (rowChanged) changed.push(r);
    });
    prev = grid.map((r) => r.map((c) => c.text + c.hl));
    const at = `${cursor.row},${cursor.col}`;
    if (!cells && at === prevCursor) return;
    prevCursor = at;
    gaps.push(now - last);
    last = now;
    log.push(`+${Math.round(now - start)}ms cells=${cells} rows=${changed.join(",")} cursor=${at}`);
    for (const r of changed.slice(0, 4)) log.push(`    ${r}: ${rowText(grid[r]!).trimEnd().slice(0, 160)}`);
  };
  await Bun.sleep(ms);
  onFlush = null;
  const sorted = [...gaps].sort((a, b) => a - b);
  const pct = (p: number) => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0);
  const summary = `frames=${gaps.length} median_gap=${pct(0.5)}ms p95_gap=${pct(0.95)}ms max_gap=${pct(1)}ms`;
  writeFileSync(join(out, "frames.log"), summary + "\n" + log.join("\n") + "\n");
  console.log(summary);
}

async function main() {
  await request("nvim_ui_attach", [cols, rows, { rgb: true, ext_linegrid: true, ext_hlstate: true }]);
  for (const step of steps) {
    const colon = step.indexOf(":");
    const kind = step.slice(0, colon);
    const arg = step.slice(colon + 1);
    if (kind === "wait") await Bun.sleep(Number(arg));
    else if (kind === "keys") await request("nvim_input", [arg]);
    else if (kind === "lua") await request("nvim_exec_lua", [arg, []]);
    else if (kind === "resize") await request("nvim_ui_try_resize", arg.split("x").map(Number));
    else if (kind === "mouse") {
      const [button, action, row, col] = arg.split(",");
      await request("nvim_input_mouse", [button, action, "", 0, Number(row), Number(col)]);
    }
    else if (kind === "snap") snap(arg);
    else if (kind === "record") await record(Number(arg));
    else if (kind === "waitfor") {
      const deadline = Date.now() + 20000;
      while (!screenText().includes(arg)) {
        if (Date.now() > deadline) throw new Error(`timed out waiting for ${JSON.stringify(arg)}`);
        await Bun.sleep(50);
      }
    } else throw new Error(`unknown step ${step}`);
  }
  console.log(`flushes=${flushes} out=${out}`);
  nvim.kill();
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  nvim.kill();
  process.exit(1);
});
