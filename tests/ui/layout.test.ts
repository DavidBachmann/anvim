import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const LONG = "a_file_with_a_rather_long_name.lua";

// The side in the prefs file, which the next start reads.
const remembered = () =>
  anvim!.ui.exec_lua<string>(`
    local f = assert(io.open(require("anvim.prefs").path))
    local side = vim.json.decode(f:read("*a")).claude_side
    f:close()
    return side
  `);

const boxes = async () => ({
  tree: await anvim!.box("tree"),
  code: await anvim!.box("code"),
  transcript: await anvim!.box("transcript"),
  input: await anvim!.box("input"),
});
type Boxes = Awaited<ReturnType<typeof boxes>>;

// The separators on both sides of the code window. The rows start below the
// notification that a toggle shows at the top right.
const walls = (lines: string[], { code }: Boxes) =>
  lines
    .slice(code.row + 4, code.row + code.height)
    .every((line) => [...line][code.col - 1] === "│" && [...line][code.col + code.width] === "│");

// Whether a row of the tree shows the name in full, within the columns at
// the tree's outer edge.
const shows = (lines: string[], tree: Box, name: string, cols: number) =>
  lines
    .slice(tree.row, tree.row + tree.height)
    .some((line) => cells(line, tree.col === 0 ? 0 : tree.col + tree.width - cols, cols).includes(name));

test("<leader>uH puts Claude on the left and the tree on the right, and back, with no frame in between, and remembers the side", async () => {
  anvim = await start({ files: { [LONG]: "return {}\n" } });
  const { ui } = anvim;
  await anvim.toCode();
  await ui.waitFor("local api = vim.api");
  const columns = await ui.exec_lua<number>("return vim.o.columns");
  const right = await boxes();
  expect(right.tree.col).toBe(0);
  expect(right.transcript.col + right.transcript.width).toBe(columns);

  let mark = ui.mark();
  await ui.input("<Space>uH");
  await ui.waitFor(async () => (await anvim!.box("transcript")).col === 0);
  const left = await boxes();
  expect(left).toEqual({
    tree: { ...right.tree, col: columns - right.tree.width },
    code: { ...right.code, col: right.transcript.width + 1 },
    transcript: { ...right.transcript, col: 0 },
    input: { ...right.input, col: 0 },
  });
  expect(await anvim.where()).toEqual({ win: "code", mode: "n" });
  expect(await remembered()).toBe("left");
  await ui.waitFor(() => walls(ui.lines(), left));
  expect(ui.frames(mark).filter((f) => !walls(f.lines, right) && !walls(f.lines, left)).length).toBe(0);

  // The tree on the right widens to the left, over the code window.
  await ui.waitFor(() => shows(ui.lines(), left.tree, "a_file_with_a_rath", left.tree.width));
  expect(shows(ui.lines(), left.tree, LONG, 60)).toBe(false);
  await ui.input("<C-w>l");
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.waitFor(() => shows(ui.lines(), left.tree, LONG, 60));
  expect(await boxes()).toEqual(left);
  await ui.input("<C-h>");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(() => walls(ui.lines(), left));
  expect(shows(ui.lines(), left.tree, LONG, 60)).toBe(false);

  mark = ui.mark();
  await ui.input("<Space>uH");
  await ui.waitFor(async () => (await anvim!.box("tree")).col === 0);
  expect(await boxes()).toEqual(right);
  expect(await anvim.where()).toEqual({ win: "code", mode: "n" });
  expect(await remembered()).toBe("right");
  expect(ui.frames(mark).filter((f) => !walls(f.lines, right) && !walls(f.lines, left)).length).toBe(0);
});

const codeWin = () => anvim!.ui.exec_lua<number>(`return require("anvim.layout").wins.code`);

test("a start after a choice of the left side is mirrored, and closed windows and a resize keep the sides", async () => {
  anvim = await start({ prefs: { claude_side: "left" } });
  const { ui } = anvim;
  await anvim.toCode();
  await ui.waitFor("local api = vim.api");
  const columns = await ui.exec_lua<number>("return vim.o.columns");
  await ui.waitFor(async () => (await anvim!.box("tree")).col + 24 === columns);
  const left = await boxes();
  expect(left.transcript.col).toBe(0);
  expect(left.input.col).toBe(0);
  expect(left.code.col).toBe(left.transcript.width + 1);
  expect(left.code.col + left.code.width + 1).toBe(left.tree.col);

  for (const keys of [":close<CR>", "<C-w>c"]) {
    await anvim.toCode();
    const win = await codeWin();
    const mark = ui.mark();
    await ui.input(keys);
    await ui.waitFor(async () => (await codeWin()) !== win);
    await anvim.waitWhere("code", "n");
    expect(await boxes()).toEqual(left);
    expect(ui.frames(mark).filter((f) => !walls(f.lines, left)).length, keys).toBe(0);
  }

  await ui.exec_lua(`vim.api.nvim_win_close(require("anvim.layout").wins.transcript, true)`);
  await ui.waitFor(async () => ui.exec_lua<boolean>(`return vim.api.nvim_win_is_valid(require("anvim.layout").wins.transcript)`));
  expect(await boxes()).toEqual(left);

  // snacks lays the explorer out again after a resize.
  await ui.resize(160, 40);
  await ui.waitFor(async () => (await anvim!.box("tree")).col === 160 - 24);
  const small = await boxes();
  expect(small.transcript).toMatchObject({ col: 0, width: Math.floor(160 * 0.36) });
  expect(small.code.col + small.code.width + 1).toBe(small.tree.col);
  await ui.resize(columns, 48);
  await ui.waitFor(async () => (await anvim!.box("tree")).col === left.tree.col);
  expect(await boxes()).toEqual(left);
});
