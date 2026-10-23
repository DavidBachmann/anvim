// A screen as a grid of cells with RGB attrs. It parses the dump that Neovim's
// TUI writes for nvim__screenshot(), renders a grid as SVG, and turns the SVG
// into a PNG with headless Chrome. The screen tool (tools/screen) and the
// debug screenshot tool share it.
import { existsSync } from "node:fs";

export const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

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
// The second cell of a wide character has the text "". Cells of one run share
// their attr object, so the renderer compares attrs by reference.
export type Cell = { text: string; attr?: Attr };
export type Pos = { row: number; col: number };
export type Colors = { fg: number; bg: number };
// Rows and columns are 0-based. The cursor is where the dump stopped printing.
export type Screen = { rows: number; cols: number; cells: Cell[][]; cursor: Pos };

const CELL_W = 9.6;
const CELL_H = 20;

export function pixels(cols: number, rows: number) {
  return { width: Math.ceil(cols * CELL_W), height: rows * CELL_H };
}

export function svg(cells: Cell[][], defaults: Colors, cursor?: Pos): string {
  const hex = (n: number) => "#" + n.toString(16).padStart(6, "0");
  const xml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const { width: w, height: h } = pixels(cells[0]?.length ?? 0, cells.length);
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" font-family="JetBrainsMono Nerd Font, Menlo, monospace" font-size="16">`,
    `<rect width="${w}" height="${h}" fill="${hex(defaults.bg)}"/>`,
  ];
  cells.forEach((row, r) => {
    let start = 0;
    for (let c = 1; c <= row.length; c++) {
      if (c < row.length && row[c]!.attr === row[start]!.attr) continue;
      const a = row[start]!.attr ?? {};
      let fg = a.foreground ?? defaults.fg;
      let bg = a.background ?? defaults.bg;
      if (a.reverse) [fg, bg] = [bg, fg];
      const x = start * CELL_W;
      const y = r * CELL_H;
      const n = c - start;
      if (bg !== defaults.bg) parts.push(`<rect x="${x}" y="${y}" width="${n * CELL_W}" height="${CELL_H}" fill="${hex(bg)}"/>`);
      const text = row
        .slice(start, c)
        .map((x) => x.text)
        .join("");
      if (text.trim()) {
        const deco = [a.underline || a.undercurl ? "underline" : "", a.strikethrough ? "line-through" : ""].join(" ").trim();
        parts.push(
          `<text x="${x}" y="${y + 15}" fill="${hex(fg)}" xml:space="preserve" textLength="${n * CELL_W}" lengthAdjust="spacingAndGlyphs"` +
            (a.bold ? ` font-weight="bold"` : "") +
            (a.italic ? ` font-style="italic"` : "") +
            (deco ? ` text-decoration="${deco}"` : "") +
            `>${xml(text)}</text>`,
        );
      }
      start = c;
    }
  });
  if (cursor) {
    parts.push(
      `<rect x="${cursor.col * CELL_W}" y="${cursor.row * CELL_H}" width="${CELL_W}" height="${CELL_H}" fill="none" stroke="${hex(defaults.fg)}"/>`,
    );
  }
  parts.push("</svg>");
  return parts.join("\n");
}

// Renders svgFile into pngFile. Returns why there is no PNG, or nothing.
export async function png(svgFile: string, pngFile: string, cols: number, rows: number): Promise<string | undefined> {
  const chrome = Bun.which(CHROME);
  if (!chrome) return `Google Chrome is not at ${CHROME}. Set CHROME to its binary.`;
  const { width, height } = pixels(cols, rows);
  let proc: Bun.Subprocess;
  try {
    proc = Bun.spawn(
      [chrome, "--headless", "--disable-gpu", "--hide-scrollbars", `--screenshot=${pngFile}`, `--window-size=${width},${height}`, `file://${svgFile}`],
      { stdout: "ignore", stderr: "ignore" },
    );
  } catch (err) {
    return `Chrome did not start: ${err}`;
  }
  const timer = setTimeout(() => proc.kill(), 20_000);
  const code = await proc.exited;
  clearTimeout(timer);
  if (code !== 0 || !existsSync(pngFile)) return `Chrome exited with ${proc.signalCode ?? code} and wrote no PNG.`;
}

// xterm's 256 colors. The first 16 are xterm's defaults, which the user's
// terminal may change.
const BASE16 = [
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5, 0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
  0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
];
function xterm(n: number): number | undefined {
  if (!(n >= 0 && n <= 255)) return;
  if (n < 16) return BASE16[n];
  if (n >= 232) return (8 + (n - 232) * 10) * 0x010101;
  const level = (v: number) => (v ? 55 + v * 40 : 0);
  n -= 16;
  return (level(Math.floor(n / 36)) << 16) | (level(Math.floor(n / 6) % 6) << 8) | level(n % 6);
}

function rgb(parts: (string | undefined)[]): number | undefined {
  const [r, g, b] = parts.map(Number);
  if ([r, g, b].some((v) => !(v! >= 0 && v! <= 255))) return;
  return (r! << 16) | (g! << 8) | b!;
}

// The color of 38, 48 or 58 in colon form: 5:n, 2:r:g:b, or 2:id:r:g:b, where
// the color space id can be empty.
function extended(sub: string[]): number | undefined {
  if (sub[0] === "5") return xterm(Number(sub[1]));
  if (sub[0] === "2") return rgb(sub.length >= 5 ? sub.slice(2, 5) : sub.slice(1, 4));
}

const COLOR_KEY = { 38: "foreground", 48: "background", 58: "special" } as const;

// Applies one SGR sequence's parameters to the current attrs.
function sgr(a: Attr, params: string): void {
  const list = params.split(";");
  for (let k = 0; k < list.length; k++) {
    const sub = list[k]!.split(":");
    const n = sub[0] === "" ? 0 : Number(sub[0]);
    if (n === 38 || n === 48 || n === 58) {
      let color: number | undefined;
      if (sub.length > 1) color = extended(sub.slice(1));
      else if (list[k + 1] === "5") {
        color = xterm(Number(list[k + 2]));
        k += 2;
      } else if (list[k + 1] === "2") {
        color = rgb(list.slice(k + 2, k + 5));
        k += 4;
      }
      if (color !== undefined) a[COLOR_KEY[n]] = color;
    } else if (n >= 30 && n <= 37) a.foreground = xterm(n - 30);
    else if (n >= 90 && n <= 97) a.foreground = xterm(n - 82);
    else if (n >= 40 && n <= 47) a.background = xterm(n - 40);
    else if (n >= 100 && n <= 107) a.background = xterm(n - 92);
    else {
      switch (n) {
        case 0:
          for (const key of Object.keys(a)) delete a[key as keyof Attr];
          break;
        case 1:
          a.bold = true;
          break;
        case 3:
          a.italic = true;
          break;
        // 4:0 ends the underline, 4:3 is a curl, and the double, dotted and
        // dashed styles draw as a plain underline.
        case 4:
          a.underline = sub[1] !== "0" && sub[1] !== "3";
          a.undercurl = sub[1] === "3";
          break;
        case 7:
          a.reverse = true;
          break;
        case 9:
          a.strikethrough = true;
          break;
        case 21:
          a.underline = true;
          a.undercurl = false;
          break;
        case 22:
          a.bold = false;
          break;
        case 23:
          a.italic = false;
          break;
        case 24:
          a.underline = a.undercurl = false;
          break;
        case 27:
          a.reverse = false;
          break;
        case 29:
          a.strikethrough = false;
          break;
        case 39:
          delete a.foreground;
          break;
        case 49:
          delete a.background;
          break;
        case 59:
          delete a.special;
          break;
      }
    }
  }
}

// Ends a string that starts with ESC ], P, _, ^ or X: at ST (ESC \), or at BEL
// for OSC. Returns the index after the end.
function skipString(s: string, i: number, bel: boolean): number {
  for (let j = i; j < s.length; j++) {
    if (bel && s[j] === "\x07") return j + 1;
    if (s[j] === "\x1b" && s[j + 1] === "\\") return j + 2;
  }
  return s.length;
}

// Plays the terminal output of a TUI screenshot onto a grid. The first line is
// "<rows>,<cols>". Sequences that do not change the cells, such as DEC private
// modes and OSC strings, are skipped.
export function parseDump(dump: string): Screen {
  const size = dump.match(/^(\d+),(\d+)\r?\n/);
  if (!size) throw new Error("The screenshot does not start with its size.");
  const rows = Number(size[1]);
  const cols = Number(size[2]);
  const interned = new Map<string, Attr>();
  const intern = (a: Attr): Attr => {
    const clean: Attr = {};
    for (const key of Object.keys(a).sort() as (keyof Attr)[]) {
      if (a[key] !== undefined && a[key] !== false) (clean as Record<string, unknown>)[key] = a[key];
    }
    const id = JSON.stringify(clean);
    if (!interned.has(id)) interned.set(id, clean);
    return interned.get(id)!;
  };
  const state: Attr = {};
  let attr = intern(state);
  const blank = (): Cell => ({ text: " ", attr: intern({ background: state.background }) });
  const cells: Cell[][] = Array.from({ length: rows }, () => Array.from({ length: cols }, () => ({ text: " ", attr })));
  let row = 0;
  let col = 0;
  let saved: Pos = { row: 0, col: 0 };
  const clampRow = (r: number) => Math.max(0, Math.min(rows - 1, r));
  // A column of `cols` means that the last cell was printed and the next
  // character wraps.
  const clampCol = (c: number) => Math.max(0, Math.min(cols - 1, c));
  const erase = (r: number, from: number, to: number) => {
    const line = cells[r];
    for (let c = Math.max(0, from); line && c < Math.min(cols, to); c++) line[c] = blank();
  };
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const print = (text: string) => {
    for (const { segment } of segmenter.segment(text)) {
      const width = Bun.stringWidth(segment);
      if (width === 0) {
        const prev = cells[row]?.[col - 1];
        if (prev) cells[row]![col - 1] = { text: prev.text + segment, attr: prev.attr };
        continue;
      }
      if (col >= cols) {
        col = 0;
        row = clampRow(row + 1);
      } else if (col + width > cols) {
        // Neovim found the glyph narrower. A cut keeps the rows below in
        // place, because the dump moves to them with relative moves.
        col = cols;
        continue;
      }
      const line = cells[row]!;
      line[col] = { text: segment, attr };
      for (let k = 1; k < width && col + k < cols; k++) line[col + k] = { text: "", attr };
      col += width;
    }
  };

  const s = dump.slice(size[0].length);
  let i = 0;
  while (i < s.length) {
    const ch = s[i]!;
    const code = ch.charCodeAt(0);
    if (code >= 0x20 && code !== 0x7f) {
      let j = i;
      while (j < s.length && s.charCodeAt(j) >= 0x20 && s.charCodeAt(j) !== 0x7f) j++;
      print(s.slice(i, j));
      i = j;
      continue;
    }
    i++;
    if (ch === "\r") col = 0;
    else if (ch === "\n" || ch === "\v" || ch === "\f") row = clampRow(row + 1);
    else if (ch === "\b") col = Math.max(0, Math.min(col, cols) - 1);
    else if (ch === "\t") col = clampCol((Math.floor(col / 8) + 1) * 8);
    else if (ch === "\x1b") {
      const next = s[i];
      i++;
      if (next === "[") {
        const m = /^([\x30-\x3f]*)([\x20-\x2f]*)([\x40-\x7e])/.exec(s.slice(i, i + 64));
        if (!m) continue;
        i += m[0].length;
        const [, params, inter, final] = m;
        // DEC private modes (CSI ? ... h/l) and other private or intermediate
        // forms do not change the cells.
        if (inter || /^[<=>?]/.test(params!)) continue;
        const nums = params!.split(";").map((p) => Number.parseInt(p, 10));
        const n = nums[0]! > 0 ? nums[0]! : 1;
        switch (final) {
          case "m":
            sgr(state, params!);
            attr = intern(state);
            break;
          case "H":
          case "f":
            row = clampRow(n - 1);
            col = clampCol((nums[1]! > 0 ? nums[1]! : 1) - 1);
            break;
          case "A":
            row = clampRow(row - n);
            break;
          case "B":
          case "e":
            row = clampRow(row + n);
            break;
          case "C":
          case "a":
            col = clampCol(col + n);
            break;
          case "D":
            col = clampCol(Math.min(col, cols) - n);
            break;
          case "E":
            row = clampRow(row + n);
            col = 0;
            break;
          case "F":
            row = clampRow(row - n);
            col = 0;
            break;
          case "G":
          case "`":
            col = clampCol(n - 1);
            break;
          case "d":
            row = clampRow(n - 1);
            break;
          case "J": {
            const mode = nums[0] || 0;
            if (mode === 0) {
              erase(row, col, cols);
              for (let r = row + 1; r < rows; r++) erase(r, 0, cols);
            } else if (mode === 1) {
              for (let r = 0; r < row; r++) erase(r, 0, cols);
              erase(row, 0, col + 1);
            } else for (let r = 0; r < rows; r++) erase(r, 0, cols);
            break;
          }
          case "K": {
            const mode = nums[0] || 0;
            if (mode === 0) erase(row, col, cols);
            else if (mode === 1) erase(row, 0, col + 1);
            else erase(row, 0, cols);
            break;
          }
          case "X":
            erase(row, col, col + n);
            break;
        }
      } else if (next === "]") i = skipString(s, i, true);
      else if (next === "P" || next === "_" || next === "^" || next === "X") i = skipString(s, i, false);
      // A charset designation, such as ESC ( B, has one more character.
      else if (next === "(" || next === ")" || next === "*" || next === "+") i++;
      else if (next === "7") saved = { row, col };
      else if (next === "8") ({ row, col } = saved);
      else if (next === "M") row = clampRow(row - 1);
      else if (next === "D") row = clampRow(row + 1);
      else if (next === "E") {
        row = clampRow(row + 1);
        col = 0;
      }
    }
  }
  return { rows, cols, cells, cursor: { row, col: clampCol(col) } };
}
