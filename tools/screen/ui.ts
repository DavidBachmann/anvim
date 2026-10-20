// A UI client for anvim. It embeds Neovim with anvim's init.lua, attaches as a
// UI with ext_linegrid and ext_hlstate, and keeps the grid, the highlight
// names, the cursor, the mode and every flushed frame. The screen tool and the
// UI tests both use it.
import { decodeMultiStream, encode } from "@msgpack/msgpack";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

export const root = resolve(import.meta.dir, "../..");
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

export type Attr = {
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
export type Cell = { text: string; hl: number };
export type Pos = { row: number; col: number };
// The screen at one flush. Rows and columns are 0-based grid cells. `changed`
// lists the rows whose text or highlights changed since the previous flush,
// and `cells` counts the changed cells.
export type Frame = { t: number; lines: string[]; cursor: Pos; mode: string; changed: number[]; cells: number };

export type StartOptions = {
  cwd: string;
  cols?: number;
  rows?: number;
  // anvim gets its state, cache, data and config dirs here.
  xdg: string;
  env?: Record<string, string>;
};

export class Ui {
  grid: Cell[][] = [];
  attrs = new Map<number, { rgb: Attr; names: string }>();
  defaults = { fg: 0xe0def4, bg: 0x191724 };
  cursor: Pos = { row: 0, col: 0 };
  mode = "";
  stderr = "";
  xdg: string;
  exitCode: number | null = null;
  readonly exited: Promise<number>;
  private proc: Bun.Subprocess<"pipe", "pipe", "pipe">;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  private log: Frame[] = [];
  // The grid at the last flush.
  private shown: Cell[][] = [];

  private constructor(opts: StartOptions) {
    this.xdg = resolve(opts.xdg);
    // The child must not see the user's anvim state, or a Neovim it runs in.
    // Without the cmux variables, it posts no notifications to the user's terminal.
    const env: Record<string, string> = {};
    for (const [key, value] of Object.entries(process.env)) {
      if (value !== undefined && !/^(XDG_|NVIM|LAZY_|CMUX_)/.test(key)) env[key] = value;
    }
    env.NVIM_APPNAME = "anvim";
    for (const name of ["config", "data", "state", "cache"]) {
      const dir = join(this.xdg, name);
      mkdirSync(dir, { recursive: true });
      env[`XDG_${name.toUpperCase()}_HOME`] = dir;
    }
    Object.assign(env, opts.env);
    this.proc = Bun.spawn(["nvim", "--embed", "-u", join(root, "init.lua")], {
      cwd: opts.cwd,
      env,
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    this.exited = this.proc.exited.then((code) => {
      this.exitCode = code;
      for (const p of this.pending.values()) p.reject(new Error(`nvim exited with ${code}`));
      this.pending.clear();
      return code;
    });
    this.read();
    this.readStderr();
  }

  static async start(opts: StartOptions): Promise<Ui> {
    const ui = new Ui(opts);
    try {
      await ui.request("nvim_ui_attach", opts.cols ?? 200, opts.rows ?? 48, {
        rgb: true,
        ext_linegrid: true,
        ext_hlstate: true,
      });
    } catch (err) {
      await ui.close();
      throw err;
    }
    return ui;
  }

  private async read() {
    try {
      for await (const msg of decodeMultiStream(this.proc.stdout)) {
        const m = msg as any[];
        if (m[0] === 1) {
          const p = this.pending.get(m[1]);
          this.pending.delete(m[1]);
          if (m[2]) p?.reject(new Error(Array.isArray(m[2]) ? String(m[2][1]) : String(m[2])));
          else p?.resolve(m[3]);
        } else if (m[0] === 2 && m[1] === "redraw") {
          for (const [name, ...calls] of m[2] as any[][]) for (const call of calls) this.handle(name as string, call);
        } else if (m[0] === 0) {
          this.write([1, m[1], null, null]);
        }
      }
    } catch {
      // The stream ends when Neovim exits.
    }
  }

  private async readStderr() {
    const decoder = new TextDecoder();
    for await (const chunk of this.proc.stderr) this.stderr += decoder.decode(chunk, { stream: true });
  }

  private write(msg: unknown[]) {
    this.proc.stdin.write(encode(msg));
    this.proc.stdin.flush();
  }

  private clear(cols: number, rows: number) {
    this.grid = Array.from({ length: rows }, () => Array.from({ length: cols }, () => ({ text: " ", hl: 0 })));
  }

  private handle(name: string, a: any[]) {
    switch (name) {
      case "grid_resize":
        this.clear(a[1], a[2]);
        break;
      case "default_colors_set":
        this.defaults = { fg: a[0] >= 0 ? a[0] : this.defaults.fg, bg: a[1] >= 0 ? a[1] : this.defaults.bg };
        break;
      case "hl_attr_define": {
        const info = (a[3] ?? []) as { hi_name?: string; ui_name?: string }[];
        const names = info
          .map((i) => i.hi_name ?? i.ui_name)
          .filter(Boolean)
          .join("+");
        this.attrs.set(a[0], { rgb: a[1], names });
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
            if (this.grid[row]?.[col]) this.grid[row][col] = { text, hl };
            col++;
          }
        }
        break;
      }
      case "grid_clear":
        this.clear(this.grid[0]?.length ?? 0, this.grid.length);
        break;
      case "grid_cursor_goto":
        this.cursor = { row: a[1], col: a[2] };
        break;
      case "grid_scroll": {
        const [, top, bot, left, right, n] = a;
        const copy = this.grid.map((r) => r.slice());
        for (let r = top; r < bot; r++) {
          const from = r + n;
          if (from < top || from >= bot) continue;
          for (let c = left; c < right; c++) this.grid[r]![c] = copy[from]![c]!;
        }
        break;
      }
      case "mode_change":
        this.mode = a[0];
        break;
      case "flush":
        this.flush();
        break;
    }
  }

  private flush() {
    const prev = this.log.at(-1)?.lines ?? [];
    const changed: number[] = [];
    let cells = 0;
    const lines = this.grid.map((row, r) => {
      const before = this.shown[r];
      let n = 0;
      row.forEach((cell, c) => {
        const old = before?.[c];
        if (!old || old.text !== cell.text || old.hl !== cell.hl) n++;
      });
      cells += n;
      if (n === 0 && prev[r] !== undefined && before?.length === row.length) return prev[r]!;
      if (n > 0) changed.push(r);
      return row.map((c) => c.text).join("");
    });
    // Cells are never changed in place, so the rows can share them.
    this.shown = this.grid.map((row) => row.slice());
    this.log.push({ t: performance.now(), lines, cursor: { ...this.cursor }, mode: this.mode, changed, cells });
  }

  request<T = any>(method: string, ...params: unknown[]): Promise<T> {
    if (this.exitCode !== null) return Promise.reject(new Error(`nvim exited with ${this.exitCode}`));
    const id = this.nextId++;
    const done = new Promise<T>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.write([0, id, method, params]);
    return done;
  }

  // Keys as a terminal sends them, e.g. "hello<CR>".
  input(keys: string): Promise<number> {
    return this.request("nvim_input", keys);
  }

  // Row and column are 0-based grid cells.
  inputMouse(button: string, action: string, row: number, col: number, modifier = ""): Promise<null> {
    return this.request("nvim_input_mouse", button, action, modifier, 0, row, col);
  }

  exec_lua<T = any>(code: string, ...args: unknown[]): Promise<T> {
    return this.request("nvim_exec_lua", code, args);
  }

  // Resolves once Neovim has handled the keys sent so far, and the callbacks
  // they scheduled. Neovim takes a request only when no typed keys are left.
  drain(): Promise<null> {
    return this.exec_lua(`
      local done = false
      vim.schedule(function()
        done = true
      end)
      vim.wait(5000, function()
        return done
      end)
    `);
  }

  resize(cols: number, rows: number): Promise<null> {
    return this.request("nvim_ui_try_resize", cols, rows);
  }

  lines(): string[] {
    return this.grid.map((r) => r.map((c) => c.text).join(""));
  }

  screen(): string {
    return this.lines().join("\n");
  }

  // The index of the next frame, to pass to frames() later.
  mark(): number {
    return this.log.length;
  }

  frames(since = 0): Frame[] {
    return this.log.slice(since);
  }

  // Waits until the screen shows text, or until the predicate returns a truthy
  // value, which it returns.
  async waitFor<T>(what: string | (() => T | Promise<T>), timeout = 10000): Promise<T | true> {
    const deadline = Date.now() + timeout;
    let last: unknown;
    while (true) {
      try {
        if (typeof what === "string") {
          if (this.screen().includes(what)) return true;
        } else {
          last = await what();
          if (last) return last as T;
        }
      } catch (err) {
        last = err;
      }
      if (this.exitCode !== null) throw new Error(`nvim exited with ${this.exitCode}\n${this.stderr}`);
      if (Date.now() > deadline) {
        const want = typeof what === "string" ? JSON.stringify(what) : `${what}\nlast: ${String(last)}`;
        throw new Error(`timed out waiting for ${want}\n${this.screen()}`);
      }
      await Bun.sleep(20);
    }
  }

  // Text runs with their highlight groups, one per line, for assertions.
  hlDump(): string {
    const lines: string[] = [];
    this.grid.forEach((row, r) => {
      let start = 0;
      for (let c = 1; c <= row.length; c++) {
        if (c < row.length && row[c]!.hl === row[start]!.hl) continue;
        const names = this.attrs.get(row[start]!.hl)?.names;
        const text = row
          .slice(start, c)
          .map((x) => x.text)
          .join("");
        if (names && text.trim()) lines.push(`r${r} c${start}-${c - 1} ${names}: ${text.trimEnd()}`);
        start = c;
      }
    });
    return lines.join("\n") + "\n";
  }

  svg(): string {
    const cw = 9.6;
    const ch = 20;
    const hex = (n: number) => "#" + n.toString(16).padStart(6, "0");
    const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const w = Math.ceil((this.grid[0]?.length ?? 0) * cw);
    const h = this.grid.length * ch;
    const parts = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" font-family="JetBrainsMono Nerd Font, Menlo, monospace" font-size="16">`,
      `<rect width="${w}" height="${h}" fill="${hex(this.defaults.bg)}"/>`,
    ];
    this.grid.forEach((row, r) => {
      let start = 0;
      for (let c = 1; c <= row.length; c++) {
        if (c < row.length && row[c]!.hl === row[start]!.hl) continue;
        const a = this.attrs.get(row[start]!.hl)?.rgb ?? {};
        let fg = a.foreground ?? this.defaults.fg;
        let bg = a.background ?? this.defaults.bg;
        if (a.reverse) [fg, bg] = [bg, fg];
        const x = start * cw;
        const y = r * ch;
        const n = c - start;
        if (bg !== this.defaults.bg) parts.push(`<rect x="${x}" y="${y}" width="${n * cw}" height="${ch}" fill="${hex(bg)}"/>`);
        const text = row
          .slice(start, c)
          .map((x) => x.text)
          .join("");
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
      `<rect x="${this.cursor.col * cw}" y="${this.cursor.row * ch}" width="${cw}" height="${ch}" fill="none" stroke="${hex(this.defaults.fg)}"/>`,
      "</svg>",
    );
    return parts.join("\n");
  }

  // Writes <name>.txt, <name>.hl.txt, <name>.svg and <name>.png (via headless Chrome) to dir.
  snap(dir: string, name: string) {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${name}.txt`), this.screen() + "\n");
    writeFileSync(join(dir, `${name}.hl.txt`), this.hlDump());
    const file = join(dir, `${name}.svg`);
    writeFileSync(file, this.svg());
    const w = Math.ceil((this.grid[0]?.length ?? 0) * 9.6);
    const h = this.grid.length * 20;
    const png = join(dir, `${name}.png`);
    Bun.spawnSync(
      [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", `--screenshot=${png}`, `--window-size=${w},${h}`, `file://${file}`],
      { stdout: "ignore", stderr: "ignore" },
    );
  }

  // Quits Neovim, which stops the sidecar. Kills it if it hangs.
  async close() {
    if (this.exitCode !== null) return;
    // A language server can outlive Neovim. lua-language-server would then
    // write into the XDG dirs after the caller deleted them. Its parent pid
    // changes when Neovim exits, so find Neovim's children before.
    let left = descendants(this.proc.pid);
    this.request("nvim_command", "qa!").catch(() => {});
    const quit = await Promise.race([this.exited.then(() => true), Bun.sleep(3000).then(() => false)]);
    if (!quit) {
      this.proc.kill();
      await this.exited;
    }
    for (const signal of ["SIGTERM", "SIGKILL"] as const) {
      left = alive(left);
      for (const pid of left.keys()) {
        try {
          process.kill(pid, signal);
        } catch {
          // It exited in the meantime.
        }
      }
      const deadline = Date.now() + 2000;
      while (left.size > 0 && Date.now() < deadline) {
        await Bun.sleep(20);
        left = alive(left);
      }
    }
  }
}

// The command line of every process below pid.
function descendants(pid: number): Map<number, string> {
  const children = new Map<number, [number, string][]>();
  for (const line of ps(["-ax", "-o", "pid=,ppid=,command="])) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (!m) continue;
    const parent = Number(m[2]);
    children.set(parent, [...(children.get(parent) ?? []), [Number(m[1]), m[3]!.trim()]]);
  }
  const found = new Map<number, string>();
  const walk = (parent: number) => {
    for (const [child, command] of children.get(parent) ?? []) {
      found.set(child, command);
      walk(child);
    }
  };
  walk(pid);
  return found;
}

// The processes that still run, with the same command line, so that a pid
// that the system gave to a new process is left alone.
function alive(procs: Map<number, string>): Map<number, string> {
  if (procs.size === 0) return procs;
  const now = new Map<number, string>();
  for (const line of ps(["-o", "pid=,command=", "-p", [...procs.keys()].join(",")])) {
    const m = line.match(/^\s*(\d+)\s+(.*)$/);
    if (m && procs.get(Number(m[1])) === m[2]!.trim()) now.set(Number(m[1]), m[2]!.trim());
  }
  return now;
}

function ps(args: string[]): string[] {
  return Bun.spawnSync(["ps", "-ww", ...args]).stdout.toString().split("\n");
}
