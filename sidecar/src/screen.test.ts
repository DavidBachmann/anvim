import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseDump, svg } from "./screen";

// Neovim 0.12.5's TUI wrote this dump under a pty, for a 40x8 screen with
// "hello wörld", "日本 wide" and "\tTab". "hello" has fg #ff0000, bg #00ff00,
// bold, italic and a #0000ff undercurl. "日本" is reverse and struck through,
// with fg #123456. Normal is #e0def4 on #191724.
const dump = readFileSync(join(import.meta.dir, "../../tests/fixtures/screenshot.cat"), "utf8");

describe("parseDump", () => {
  test("plays a real TUI screenshot onto cells with their colors", () => {
    const screen = parseDump(dump);
    expect([screen.rows, screen.cols]).toEqual([8, 40]);
    const lines = screen.cells.map((row) => row.map((c) => c.text).join(""));
    expect(lines.slice(0, 3).map((l) => l.trimEnd())).toEqual(["hello wörld", "日本 wide", "        Tab"]);
    expect(lines[6]).toBe("[No Name] [+]         3,1-8          All");
    expect(screen.cells[0]![0]!.attr).toEqual({
      foreground: 0xff0000,
      background: 0x00ff00,
      special: 0x0000ff,
      bold: true,
      italic: true,
      undercurl: true,
    });
    expect(screen.cells[0]![5]!.attr).toEqual({ foreground: 0xe0def4, background: 0x191724 });
    // A wide character takes two cells, and the second one is empty.
    expect(screen.cells[1]!.slice(0, 4).map((c) => c.text)).toEqual(["日", "", "本", ""]);
    expect(screen.cells[1]![1]!.attr).toEqual({
      foreground: 0x123456,
      background: 0x191724,
      reverse: true,
      strikethrough: true,
    });
    expect(screen.cells[6]![0]!.attr?.background).toBe(0x4f5258);
    // The dump ends after the last cell, not at Neovim's cursor.
    expect(screen.cursor).toEqual({ row: 7, col: 39 });
    const out = svg(screen.cells, { fg: 0xe0def4, bg: 0x191724 });
    expect(out).toContain(`fill="#ff0000"`);
    expect(out).toContain(">hello</text>");
  });

  test("reads the forms that other terminals get", () => {
    const screen = parseDump(
      "2,10\n\x1b]11;?\x07\x1b[?2026h\x1b[2;3H\x1b[38;2;1;2;3;48;5;196mab\x1b[0m\x1b[1;1H\x1b[4:3;91mc\x1b[24;39mde\x1b[?2026l",
    );
    expect(screen.cells[1]![2]).toEqual({ text: "a", attr: { foreground: 0x010203, background: 0xff0000 } });
    expect(screen.cells[0]![0]).toEqual({ text: "c", attr: { foreground: 0xff0000, undercurl: true } });
    expect(screen.cells[0]![1]!.attr).toEqual({});
    expect(screen.cursor).toEqual({ row: 0, col: 3 });
  });
});
