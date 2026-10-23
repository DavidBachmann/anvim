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
