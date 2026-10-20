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
  expect(tree.width).toBe(24);
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

test("the focused tree widens again when a folder opens", async () => {
  const deep = "the_deepest_file_name_in_this_folder.lua";
  anvim = await start({ files: { [`sub/${deep}`]: "return {}\n" } });
  const { ui } = anvim;
  await anvim.toCode();
  // The user's config fires FileType again 100 ms after lspconfig loads. From
  // the tree, that fails in the list's buffer, and the error's popup would
  // widen the tree here too.
  await ui.waitFor(() => ui.exec_lua(`return require("lazy.core.config").plugins["nvim-lspconfig"]._.loaded ~= nil`));
  await Bun.sleep(300);
  const tree = await anvim.box("tree");
  await ui.input("<C-w>h");
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.waitFor(() => shows(ui.lines(), tree, " sub", tree.width));
  await ui.exec_lua(`
    local list = require("anvim.tree").explorer().list
    for i = 1, list:count() do
      if list:get(i).file:match("/sub$") then
        list:view(i)
      end
    end
  `);
  await ui.input("<CR>");
  // At once, and not at some later window event.
  await ui.waitFor(() => shows(ui.lines(), tree, deep), 300);
  expect(await anvim.where()).toEqual({ win: "snacks_picker_list", mode: "n" });
});
