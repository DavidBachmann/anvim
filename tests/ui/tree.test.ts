import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, cursorIn, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const LONG = "a_file_with_a_rather_long_name.lua";

// Every row of the box has the separator in the column.
const wall = (lines: string[], box: Box, col: number) =>
  lines.slice(box.row, box.row + box.height).every((line) => [...line][col] === "│");

// Whether a row of the tree shows the name in full, within its first columns.
const shows = (lines: string[], tree: Box, name: string, cols = 80) =>
  lines.slice(tree.row, tree.row + tree.height).some((line) => cells(line, 0, cols).includes(name));

test("the tree is narrow without focus, and with focus its list widens over the code window", async () => {
  anvim = await start({ files: { [LONG]: "return {}\n" } });
  const { ui } = anvim;
  await anvim.toCode();
  await ui.waitFor("local api = vim.api");
  const tree = await anvim.box("tree");
  const code = await anvim.box("code");
  expect(tree.width).toBe(30);
  await ui.waitFor(() => shows(ui.lines(), tree, "a_file_with_a_rath", tree.width));
  expect(shows(ui.lines(), tree, LONG)).toBe(false);
  expect(wall(ui.lines(), code, tree.width)).toBe(true);

  let mark = ui.mark();
  await ui.input("<C-w>h");
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.waitFor(() => shows(ui.lines(), tree, LONG));
  expect(await anvim.box("tree")).toEqual(tree);
  expect(await anvim.box("code")).toEqual(code);
  // No frame shows the focused tree at its narrow width.
  const narrow = ui.frames(mark).filter((f) => cursorIn([f], tree).length > 0 && wall(f.lines, code, tree.width));
  expect(narrow.length).toBe(0);

  mark = ui.mark();
  await ui.input("<C-w>l");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(() => wall(ui.lines(), code, tree.width));
  expect(shows(ui.lines(), tree, LONG)).toBe(false);
  // No frame shows the code window's cursor beside the wide tree.
  const wide = ui.frames(mark).filter((f) => cursorIn([f], code).length > 0 && !wall(f.lines, code, tree.width));
  expect(wide.length).toBe(0);
});

// The choice in the prefs file, which the next start reads.
const minimizes = () =>
  anvim!.ui.exec_lua<boolean>(`
    local f = assert(io.open(require("anvim.prefs").path))
    local on = vim.json.decode(f:read("*a")).explorer_minimize
    f:close()
    return on
  `);

// The code window's left separator, below the notification that a toggle
// shows at the top right, and whether the tree shows the name in full.
const state = (lines: string[], code: Box) => ({
  wall: lines.slice(code.row + 4, code.row + code.height).every((line) => [...line][code.col - 1] === "│"),
  long: lines.some((line) => cells(line, 0, code.col).includes(LONG)),
});

test("<leader>ue keeps the tree at the width of its names, beside the code window, with no frame in between, and remembers it", async () => {
  anvim = await start({ files: { [LONG]: "return {}\n" } });
  const { ui } = anvim;
  await anvim.toCode();
  await ui.waitFor("local api = vim.api");
  const narrow = await anvim.box("tree");
  const code = await anvim.box("code");
  await ui.waitFor(() => shows(ui.lines(), narrow, "a_file_with_a_rath", narrow.width));

  let mark = ui.mark();
  await ui.input("<Space>ue");
  await ui.waitFor(async () => (await anvim!.box("tree")).width > narrow.width);
  const tree = await anvim.box("tree");
  const beside = { ...code, col: tree.width + 1, width: code.width - tree.width + narrow.width };
  expect(await anvim.box("code")).toEqual(beside);
  expect(await minimizes()).toBe(false);
  await ui.waitFor(() => state(ui.lines(), beside).wall && state(ui.lines(), beside).long);
  const torn = (lines: string[]) => {
    const before = state(lines, code);
    const after = state(lines, beside);
    return !(before.wall && !before.long) && !(after.wall && after.long);
  };
  expect(ui.frames(mark).filter((f) => torn(f.lines)).length).toBe(0);

  // Focus changes no width.
  await ui.input("<C-w>h");
  await anvim.waitWhere("snacks_picker_list", "n");
  expect(await anvim.box("tree")).toEqual(tree);
  expect(await anvim.box("code")).toEqual(beside);
  await ui.input("<C-w>l");
  await anvim.waitWhere("code", "n");
  expect(await anvim.box("tree")).toEqual(tree);
  expect(state(ui.lines(), beside)).toEqual({ wall: true, long: true });

  mark = ui.mark();
  await ui.input("<Space>ue");
  await ui.waitFor(async () => (await anvim!.box("tree")).width === narrow.width);
  expect(await anvim.box("code")).toEqual(code);
  expect(await minimizes()).toBe(true);
  await ui.waitFor(() => state(ui.lines(), code).wall && !state(ui.lines(), code).long);
  expect(ui.frames(mark).filter((f) => torn(f.lines)).length).toBe(0);
});
