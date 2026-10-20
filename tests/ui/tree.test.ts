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

// Sends events to the plugin as the sidecar would.
const dispatch = (...events: Record<string, unknown>[]) =>
  anvim!.ui.exec_lua(`for _, ev in ipairs({ ... }) do require("anvim.sidecar").dispatch(ev) end`, ...events);

const agentStart = (id: string) => ({
  type: "agent_start",
  agent_id: id,
  tool_use_id: `tu_${id}`,
  description: `Task ${id}`,
  depth: 1,
  background: false,
});

// An Edit's tool call by a subagent.
const edit = (id: string, path: string, agent: string) => ({
  type: "tool_use",
  id,
  name: "Edit",
  input: { file_path: path, old_string: "a", new_string: "b" },
  parent_id: `tu_${agent}`,
  agent_id: agent,
});

// The main agent's path, which streams before the rest of its Edit.
const mainEdit = (id: string, path: string) => ({
  type: "tool_field",
  id,
  name: "Edit",
  key: "file_path",
  phase: "end",
  value: path,
});

const turnEnd = { type: "turn_end", subtype: "success", is_error: false, duration_ms: 1, cost_usd: 0 };

// The grid row of the tree that shows a name.
const rowOf = (lines: string[], tree: Box, name: string, width = tree.width) =>
  lines.findIndex((line, row) => row >= tree.row && row < tree.row + tree.height && cells(line, 0, width).includes(name));

// The dots on a grid row of the tree, with their foreground colors.
const dots = (row: number, width: number) =>
  anvim!.ui.grid[row]!.slice(0, width).flatMap((cell) =>
    cell.text === "⏺" || cell.text === "+" ? [{ text: cell.text, fg: anvim!.ui.attrs.get(cell.hl)?.rgb.foreground }] : [],
  );

// The column of a diagnostic's icon on a grid row of the tree, or -1.
const diagnostic = (row: number, width: number) =>
  anvim!.ui.grid[row]!.slice(0, width).findIndex((cell) =>
    (anvim!.ui.attrs.get(cell.hl)?.names ?? "").split("+").includes("DiagnosticError"),
  );

const colors = (): Promise<Record<string, number>> =>
  anvim!.ui.exec_lua(`
    local ret = {}
    for _, name in ipairs({ "AnvimClaude", "AnvimAgent1", "AnvimAgent2" }) do
      ret[name] = vim.api.nvim_get_hl(0, { name = name, link = false }).fg
    end
    return ret
  `);

const listView = () =>
  anvim!.ui.exec_lua(`
    local list = require("anvim.tree").explorer().list
    return { top = list.top, cursor = list.cursor, win = vim.api.nvim_win_get_cursor(list.win.win) }
  `);

test("agents' dots mark the files they write to and the closed folders above them, and go when the agents end", async () => {
  anvim = await start({ files: { "alpha.js": "a\n", "sub/beta.js": "b\n" } });
  const { ui, dir } = anvim;
  const tree = await anvim.box("tree");
  await ui.waitFor(() => rowOf(ui.lines(), tree, " alpha.js") >= 0 && rowOf(ui.lines(), tree, " sub") >= 0);
  // A diagnostic's icon also sits at the right edge.
  await ui.exec_lua(
    `
    local buf = vim.fn.bufadd(...)
    vim.fn.bufload(buf)
    local ns = vim.api.nvim_create_namespace("tree.test")
    vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "x", severity = vim.diagnostic.severity.ERROR } })
  `,
    `${dir}/alpha.js`,
  );
  const alpha = rowOf(ui.lines(), tree, " alpha.js");
  const sub = rowOf(ui.lines(), tree, " sub");
  await ui.waitFor(() => diagnostic(alpha, tree.width) >= 0);
  const hl = await colors();
  const view = await listView();
  const where = await anvim.where();
  const cursor = { ...ui.cursor };
  const mark = ui.mark();

  await dispatch(
    agentStart("a1"),
    agentStart("a2"),
    edit("e1", `${dir}/alpha.js`, "a1"),
    edit("e2", `${dir}/sub/beta.js`, "a2"),
    mainEdit("m1", `${dir}/alpha.js`),
  );
  await ui.waitFor(() => dots(alpha, tree.width).length === 2 && dots(sub, tree.width).length === 1);
  expect(dots(alpha, tree.width)).toEqual([
    { text: "⏺", fg: hl.AnvimClaude },
    { text: "⏺", fg: hl.AnvimAgent1 },
  ]);
  expect(dots(sub, tree.width)).toEqual([{ text: "⏺", fg: hl.AnvimAgent2 }]);
  // The dots are the outermost mark, and the diagnostic moves left of them.
  expect(cells(ui.lines()[alpha]!, tree.width - 3, 3)).toBe("⏺⏺ ");
  expect(diagnostic(alpha, tree.width)).toBeLessThan(tree.width - 3);

  await dispatch({ type: "agent_end", agent_id: "a2", status: "completed", summary: "done" });
  await ui.waitFor(() => dots(sub, tree.width).length === 0);
  expect(dots(alpha, tree.width).length).toBe(2);
  await dispatch(turnEnd);
  await ui.waitFor(() => dots(alpha, tree.width).length === 0);
  expect(diagnostic(alpha, tree.width)).toBe(tree.width - 2);

  // Neither the cursor nor the tree's view moved.
  const moved = ui.frames(mark).filter((f) => f.cursor.row !== cursor.row || f.cursor.col !== cursor.col);
  expect(moved.length).toBe(0);
  expect(await anvim.where()).toEqual(where);
  expect(await listView()).toEqual(view);
});

test("the focused tree widens to fit the dots, in the frame that shows them", async () => {
  anvim = await start({ files: { [LONG]: "return {}\n", "short.lua": "return 1\n" } });
  const { ui, dir } = anvim;
  await anvim.toCode();
  // The user's config fires FileType again 100 ms after lspconfig loads, and
  // the error's popup from the tree's buffer would widen the tree.
  await ui.waitFor(() => ui.exec_lua(`return require("lazy.core.config").plugins["nvim-lspconfig"]._.loaded ~= nil`));
  await Bun.sleep(300);
  const tree = await anvim.box("tree");
  await ui.input("<C-w>h");
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.waitFor(() => rowOf(ui.lines(), tree, LONG, 80) >= 0);
  await ui.input("j");
  await anvim.waitWhere("snacks_picker_list", "n");
  const listWidth = () => ui.exec_lua<number>(`return vim.api.nvim_win_get_width(require("anvim.tree").explorer().list.win.win)`);
  const before = await listWidth();
  expect(before).toBeGreaterThan(tree.width);
  const row = rowOf(ui.lines(), tree, LONG, 80);
  const view = await listView();
  const cursor = { ...ui.cursor };
  const mark = ui.mark();

  await dispatch(
    agentStart("b1"),
    agentStart("b2"),
    edit("e1", `${dir}/${LONG}`, "b1"),
    edit("e2", `${dir}/${LONG}`, "b2"),
    mainEdit("m1", `${dir}/${LONG}`),
  );
  await ui.waitFor(() => dots(row, 80).length === 3);
  // One column for the mark, three dots and a space.
  expect(await listWidth()).toBe(before + 5);
  const covered = ui.frames(mark).filter((f) => f.lines[row]!.includes("⏺") && !f.lines[row]!.includes(LONG));
  expect(covered.length).toBe(0);
  const moved = ui.frames(mark).filter((f) => f.cursor.row !== cursor.row || f.cursor.col !== cursor.col);
  expect(moved.length).toBe(0);
  expect(await anvim.where()).toEqual({ win: "snacks_picker_list", mode: "n" });
  expect(await listView()).toEqual(view);
});
