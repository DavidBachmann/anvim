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

test("the focused tree widens again when a folder opens", async () => {
  const deep = "the_deepest_file_name_in_this_folder.lua";
  anvim = await start({ files: { [`sub/${deep}`]: "return {}\n" } });
  const { ui } = anvim;
  await anvim.toCode();
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
  const mark = ui.mark();
  await ui.input("<CR>");
  // At once, and not at some later window event.
  await ui.waitFor(() => shows(ui.lines(), tree, deep), 300);
  expect(await anvim.where()).toEqual({ win: "snacks_picker_list", mode: "n" });
  // No frame shows the new rows at the old width.
  const cut = ui.frames(mark).filter((f) => shows(f.lines, tree, "the_deepest") && !shows(f.lines, tree, deep));
  expect(cut.length).toBe(0);
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

// The separators on both sides of the code window, below the notification.
const walls = (lines: string[], code: Box) =>
  lines
    .slice(code.row + 4, code.row + code.height)
    .every((line) => [...line][code.col - 1] === "│" && [...line][code.col + code.width] === "│");

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

test("a start with auto-minimize off opens the tree at the width of its names, and a side swap keeps it", async () => {
  anvim = await start({ files: { [LONG]: "return {}\n" }, prefs: { explorer_minimize: false } });
  const { ui } = anvim;
  await anvim.toCode();
  await ui.waitFor("local api = vim.api");
  await ui.waitFor(async () => (await anvim!.box("tree")).width > 30);
  const tree = await anvim.box("tree");
  const code = await anvim.box("code");
  expect(code.col).toBe(tree.width + 1);
  await ui.waitFor(() => state(ui.lines(), code).long);
  // From the first frame with rows, the tree has the width of its names.
  const rows = ui.frames(0).filter((f) => shows(f.lines, tree, "matchparen", tree.width));
  expect(rows.length).toBeGreaterThan(0);
  expect(rows.filter((f) => !state(f.lines, code).wall).length).toBe(0);

  const columns = await ui.exec_lua<number>("return vim.o.columns");
  const mark = ui.mark();
  await ui.input("<Space>uH");
  await ui.waitFor(async () => (await anvim!.box("tree")).col > 0);
  expect(await anvim.box("tree")).toEqual({ ...tree, col: columns - tree.width });
  const mirrored = await anvim.box("code");
  expect(mirrored.col + mirrored.width + 1).toBe(columns - tree.width);
  await ui.waitFor(() => ui.lines().some((line) => cells(line, columns - tree.width, tree.width).includes(LONG)));
  await ui.waitFor(() => walls(ui.lines(), mirrored));
  expect(ui.frames(mark).filter((f) => !walls(f.lines, code) && !walls(f.lines, mirrored)).length).toBe(0);
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
    ["⏺", "•", "+"].includes(cell.text) ? [{ text: cell.text, fg: anvim!.ui.attrs.get(cell.hl)?.rgb.foreground }] : [],
  );

// The dots on a grid row of the tree, each with the group of `hl` that has its color.
const groups = (row: number, width: number, hl: Record<string, number>) =>
  dots(row, width).map(({ text, fg }) => `${text} ${Object.keys(hl).find((name) => hl[name] === fg) ?? fg}`);

// The column of a diagnostic's icon on a grid row of the tree, or -1.
const diagnostic = (row: number, width: number) =>
  anvim!.ui.grid[row]!.slice(0, width).findIndex((cell) =>
    (anvim!.ui.attrs.get(cell.hl)?.names ?? "").split("+").includes("DiagnosticError"),
  );

const colors = (): Promise<Record<string, number>> =>
  anvim!.ui.exec_lua(`
    local ret = {}
    for _, name in ipairs({ "AnvimClaude", "AnvimAgent1", "AnvimAgent2", "AnvimAgent3" }) do
      ret[name] = vim.api.nvim_get_hl(0, { name = name, link = false }).fg
    end
    return ret
  `);

const listView = () =>
  anvim!.ui.exec_lua(`
    local list = require("anvim.tree").explorer().list
    return { top = list.top, cursor = list.cursor, win = vim.api.nvim_win_get_cursor(list.win.win) }
  `);

test("agents' dots mark their places and the files they write to, and the closed folders above them, and go when the agents end", async () => {
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
  // The main agent writes alpha.js, and a1's place is there.
  expect(dots(alpha, tree.width)).toEqual([
    { text: "•", fg: hl.AnvimClaude },
    { text: "⏺", fg: hl.AnvimAgent1 },
  ]);
  expect(dots(sub, tree.width)).toEqual([{ text: "⏺", fg: hl.AnvimAgent2 }]);
  // The dots are the outermost mark, and the diagnostic moves left of them.
  expect(cells(ui.lines()[alpha]!, tree.width - 3, 3)).toBe("•⏺ ");
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

test("during a replay of three agents, each agent's place shows a ⏺ and the other files it wrote a •", async () => {
  const files: Record<string, string> = {};
  for (const name of ["alpha", "beta", "gamma"]) {
    files[`${name}.js`] = `export function ${name}() {\n  return "${name}";\n}\n`;
  }
  // The replay stops while all three agents run, after alpha's edit.
  const cut = (frames: string[]) =>
    frames.slice(0, frames.findIndex((f) => f.includes('"type":"tool_result","id":"toolu_01FmrQ4dnbD1pfSoD99kDRHb"')) + 1);
  anvim = await start({ recording: "agents-session.jsonl", frames: cut, files, env: { ANVIM_REPLAY_SPEED: "4" } });
  const { ui, dir } = anvim;
  const tree = await anvim.box("tree");
  const row = (name: string) => rowOf(ui.lines(), tree, ` ${name}.js`);
  await ui.waitFor(() => row("alpha") >= 0 && row("beta") >= 0 && row("gamma") >= 0);
  const [alpha, beta, gamma] = [row("alpha"), row("beta"), row("gamma")];
  const hl = await colors();
  await ui.exec_lua(`require("anvim.input").send("Edit the three files")`);
  await ui.waitFor(() => groups(gamma, tree.width, hl).length === 1, 10000);
  expect([groups(alpha, tree.width, hl), groups(beta, tree.width, hl), groups(gamma, tree.width, hl)]).toEqual([
    ["⏺ AnvimAgent1"],
    ["⏺ AnvimAgent2"],
    ["⏺ AnvimAgent3"],
  ]);
  await ui.waitFor(() => ui.exec_lua<boolean>(`return #require("anvim.agents").get("adc8e994a94d15f64").files == 1`));

  // alpha's agent reads gamma.js: its place moves there, and alpha.js keeps a • for its edit.
  await dispatch({
    type: "tool_use",
    id: "read_gamma",
    name: "Read",
    input: { file_path: `${dir}/gamma.js` },
    parent_id: "toolu_01G1zf59XnZb8KKDJharP7iV",
    agent_id: "adc8e994a94d15f64",
  });
  await ui.waitFor(() => groups(gamma, tree.width, hl).length === 2);
  expect(groups(alpha, tree.width, hl)).toEqual(["• AnvimAgent1"]);
  expect(groups(gamma, tree.width, hl)).toEqual(["⏺ AnvimAgent1", "⏺ AnvimAgent3"]);
  expect(cells(ui.lines()[gamma]!, tree.width - 3, 3)).toBe("⏺⏺ ");

  // A move within gamma.js leaves the tree's rows as they are.
  const treeRows = (lines: string[]) =>
    lines
      .slice(tree.row, tree.row + tree.height)
      .map((line) => cells(line, 0, tree.width))
      .join("\n");
  const before = treeRows(ui.lines());
  const within = ui.mark();
  await dispatch({
    type: "tool_use",
    id: "read_gamma_2",
    name: "Read",
    input: { file_path: `${dir}/gamma.js`, offset: 2 },
    parent_id: "toolu_01G1zf59XnZb8KKDJharP7iV",
    agent_id: "adc8e994a94d15f64",
  });
  await Bun.sleep(100);
  await ui.drain();
  expect(ui.frames(within).filter((f) => treeRows(f.lines) !== before).length).toBe(0);

  await dispatch({ type: "agent_end", agent_id: "adc8e994a94d15f64", status: "completed", summary: "done" });
  await ui.waitFor(() => groups(gamma, tree.width, hl).length === 1);
  expect([groups(alpha, tree.width, hl), groups(beta, tree.width, hl), groups(gamma, tree.width, hl)]).toEqual([
    [],
    ["⏺ AnvimAgent2"],
    ["⏺ AnvimAgent3"],
  ]);
  await dispatch(turnEnd);
  await ui.waitFor(() => groups(beta, tree.width, hl).length + groups(gamma, tree.width, hl).length === 0);
});
