// The : command line opens in a window over the code, so that it never looks
// like the prompt. Search stays at the bottom.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const TITLE = " Command line ";

// The popup's text row, inside its border, or null.
const popup = (lines: string[]): Box | null => {
  const top = lines.findIndex((line) => line.includes(TITLE));
  if (top < 0) return null;
  const chars = [...lines[top]!];
  const left = chars.indexOf("╭");
  return { row: top + 1, col: left + 1, width: chars.indexOf("╮") - left - 1, height: 1 };
};

const text = (lines: string[], box: Box) => cells(lines[box.row]!, box.col, box.width).trimEnd();
const bottom = (lines: string[]) => lines.at(-1)!.trim();

// ui2's own float for the command line, as ui2 placed it.
const ui2Float = () =>
  anvim!.ui.exec_lua<{ relative: string; wrap: boolean }>(`
    local win = require("vim._core.ui2").wins.cmd
    return { relative = vim.api.nvim_win_get_config(win).relative, wrap = vim.wo[win].wrap }
  `);

test(": opens the command line over the code window in its first frame, and Esc closes it", async () => {
  anvim = await start();
  const { ui } = anvim;
  const code = await anvim.box("code");
  const before = await ui2Float();
  const mark = ui.mark();
  await ui.input(":");
  await ui.waitFor(() => popup(ui.lines()) !== null);
  const box = popup(ui.lines())!;
  expect(text(ui.lines(), box)).toBe(":");
  expect(inBox(ui.cursor, box)).toBe(true);
  expect(box.col - 1).toBeGreaterThanOrEqual(code.col);
  expect(box.col + box.width + 1).toBeLessThanOrEqual(code.col + code.width);
  expect(bottom(ui.lines())).toBe("");
  // No frame shows the command line at the bottom first. 'showcmd' may show
  // the : at the right end of that row for a moment.
  expect(ui.frames(mark).filter((f) => f.lines.at(-1)!.startsWith(":")).length).toBe(0);

  await ui.input('echo "hello"');
  await ui.waitFor(() => text(ui.lines(), box) === ':echo "hello"');
  expect(inBox(ui.cursor, box)).toBe(true);
  // A long command scrolls in its row, and the windows stay where they are.
  await ui.input("x".repeat(120));
  await ui.waitFor(() => text(ui.lines(), box).endsWith("xxxx"));
  expect(popup(ui.lines())).toEqual(box);
  expect(await ui.exec_lua<number>("return vim.o.cmdheight")).toBe(1);
  expect(await anvim.box("code")).toEqual(code);

  await ui.input("<Esc>");
  await ui.waitFor(() => popup(ui.lines()) === null);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
  expect(bottom(ui.lines())).toBe("");
  expect(await ui2Float()).toEqual(before);
});

test("a command from the popup runs, and its output shows at the bottom", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.input(':echo "ran from the popup"<CR>');
  await ui.waitFor(() => bottom(ui.lines()) === "ran from the popup");
  expect(popup(ui.lines())).toBeNull();
});

// ui2 keeps messages that fill more rows open while a : command line opens,
// and moves them above it.
test("the popup opens with its border while long messages show", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.input(':echo "one\\ntwo\\nthree"<CR>');
  await ui.waitFor(() => ui.lines().some((line) => line.trim() === "three"));
  await ui.input(":");
  await ui.waitFor(() => popup(ui.lines()) !== null);
  const box = popup(ui.lines())!;
  expect(text(ui.lines(), box)).toBe(":");
  expect(inBox(ui.cursor, box)).toBe(true);
  await ui.input("<Esc>");
  await ui.waitFor(() => popup(ui.lines()) === null);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
});

test("search stays at the bottom", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode();
  await ui.input("/local");
  await ui.waitFor(() => bottom(ui.lines()) === "/local");
  expect(popup(ui.lines())).toBeNull();
  await ui.input("<Esc>");
  await anvim.waitWhere("code", "n");
});
