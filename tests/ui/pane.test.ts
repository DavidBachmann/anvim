// The tool pane under the code window: the main agent's tool calls, or the
// followed subagent's, in a window that takes no focus.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, cursorIn, inBox, quiet, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const send = async (text: string) => {
  await anvim!.insert();
  await anvim!.ui.input(text);
  await anvim!.hideMenu();
  await anvim!.ui.input("<CR>");
};

// A turn of the edit session, which reads and edits matchparen.lua.
async function editTurn() {
  anvim = await start({ prefs: { tool_pane: true } });
  const { ui } = anvim;
  await send("Add a comment");
  await ui.waitFor("Added 1 line", 20000);
  await ui.waitFor(() => ui.exec_lua<boolean>(`return not require("anvim.state").busy`));
  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  return anvim;
}

const hasPane = () =>
  anvim!.ui.exec_lua<boolean>(`
    local pane = require("anvim.layout").wins.pane
    return pane ~= nil and vim.api.nvim_win_is_valid(pane)
  `);

const rows = (lines: string[], box: Box) =>
  lines.slice(box.row, box.row + box.height).map((l) => cells(l, box.col, box.width));

// The groups of the cell, outermost last.
const hlNames = (row: number, col: number) =>
  anvim!.ui.attrs.get(anvim!.ui.grid[row]![col]!.hl)?.names.split("+") ?? [];

test("<leader>us closes and opens the pane with no frame in between, and the chat keeps its count line", async () => {
  const { ui } = await editTurn();
  const pane = await anvim!.box("pane");
  const code = await anvim!.box("code");
  // The code window's text rows, its separator, the pane's winbar and rows.
  expect(code.row + code.height + 2).toBe(pane.row);
  expect({ col: pane.col, width: pane.width }).toEqual({ col: code.col, width: code.width });
  expect(rows(ui.lines(), pane).some((r) => r.includes("⏺ Edit(matchparen.lua)"))).toBe(true);
  expect(cells(ui.lines()[pane.row - 1]!, pane.col, 12)).toBe(" Tool calls ");
  const transcript = await anvim!.box("transcript");
  expect(rows(ui.lines(), transcript).some((r) => r.includes("⎿  2 tool calls"))).toBe(true);
  expect(rows(ui.lines(), transcript).some((r) => r.includes("⏺ Read("))).toBe(false);

  const sepRow = pane.row - 2;
  const on = (lines: string[]) =>
    /^─+$/.test(cells(lines[sepRow]!, code.col, code.width)) &&
    cells(lines[pane.row - 1]!, pane.col, 11) === " Tool calls" &&
    rows(lines, pane).some((r) => r.includes("⏺ Edit(matchparen.lua)"));
  const off = (lines: string[]) =>
    !cells(lines[sepRow]!, code.col, code.width).includes("─") &&
    !rows(lines, pane).some((r) => r.includes("Tool calls") || r.includes("⏺ Edit("));

  let mark = ui.mark();
  await ui.input("<Space>us");
  await ui.waitFor(async () => !(await hasPane()));
  await quiet(ui);
  expect(off(ui.lines())).toBe(true);
  expect(await anvim!.box("code")).toEqual({ ...code, height: code.height + 2 + pane.height });
  expect(ui.frames(mark).filter((f) => !on(f.lines) && !off(f.lines)).length).toBe(0);
  expect(await anvim!.where()).toEqual({ win: "input", mode: "n" });

  mark = ui.mark();
  await ui.input("<Space>us");
  await ui.waitFor(hasPane);
  await quiet(ui);
  expect(on(ui.lines())).toBe(true);
  expect(await anvim!.box("pane")).toEqual(pane);
  expect(ui.frames(mark).filter((f) => !on(f.lines) && !off(f.lines)).length).toBe(0);
  expect(rows(ui.lines(), transcript).some((r) => r.includes("⎿  2 tool calls"))).toBe(true);
});

test("window keys skip the pane, and a click on it goes back to the window the cursor left", async () => {
  const { ui } = await editTurn();
  const pane = await anvim!.box("pane");
  await anvim!.toCode("matchparen.lua", { lnum: 30, topline: 20 });
  const code = await anvim!.box("code");
  const cursor = () => ui.exec_lua<number[]>(`return vim.api.nvim_win_get_cursor(0)`);

  // <C-j> from the code window, and <C-h> from the prompt, whose rows are the pane's.
  const at = await cursor();
  let mark = ui.mark();
  await ui.input("<C-j>");
  await ui.drain();
  await quiet(ui);
  expect(await anvim!.where()).toEqual({ win: "code", mode: "n" });
  expect(await cursor()).toEqual(at);
  await ui.input("<C-l>");
  await anvim!.waitWhere("input", "n");
  await ui.input("<C-h>");
  await anvim!.waitWhere("code", "n");
  await quiet(ui);
  expect(cursorIn(ui.frames(mark), { ...pane, row: pane.row - 1, height: pane.height + 1 })).toEqual([]);

  // A click from the code window leaves its cursor and view where they were.
  const view = () => ui.exec_lua<{ lnum: number; topline: number }>(`return vim.fn.winsaveview()`);
  let before = await view();
  mark = ui.mark();
  await ui.inputMouse("left", "press", pane.row + 1, pane.col + 4);
  await ui.inputMouse("left", "release", pane.row + 1, pane.col + 4);
  await ui.drain();
  await quiet(ui);
  expect(await anvim!.where()).toEqual({ win: "code", mode: "n" });
  expect(await view()).toMatchObject({ lnum: before.lnum, topline: before.topline });
  expect(ui.frames(mark).filter((f) => !inBox(f.cursor, code)).map((f) => f.cursor)).toEqual([]);

  // More clicks, and <C-w>p still goes to the prompt, where the cursor was before.
  for (let i = 0; i < 2; i++) {
    await Bun.sleep(600);
    await ui.inputMouse("left", "press", pane.row + 1, pane.col + 4);
    await ui.inputMouse("left", "release", pane.row + 1, pane.col + 4);
    await ui.drain();
  }
  expect(await anvim!.where()).toEqual({ win: "code", mode: "n" });
  await ui.input("<C-w>p");
  await anvim!.waitWhere("input", "n");
  await ui.input("<C-h>");
  await anvim!.waitWhere("code", "n");
  before = await view();

  // A drag across the pane selects nothing in the code window.
  await Bun.sleep(600);
  mark = ui.mark();
  await ui.inputMouse("left", "press", pane.row + 1, pane.col + 4);
  await ui.inputMouse("left", "drag", pane.row + 2, pane.col + 20);
  await ui.inputMouse("left", "drag", pane.row + 3, pane.col + 30);
  await ui.inputMouse("left", "release", pane.row + 3, pane.col + 30);
  await ui.drain();
  await quiet(ui);
  expect(await anvim!.where()).toEqual({ win: "code", mode: "n" });
  expect(await view()).toMatchObject({ lnum: before.lnum, topline: before.topline });
  expect(ui.frames(mark).filter((f) => f.mode.startsWith("visual")).length).toBe(0);

  // A click from insert mode in the prompt keeps typing where it was.
  await Bun.sleep(600);
  await ui.input("<C-l>");
  await anvim!.waitWhere("input", "n");
  await anvim!.insert();
  await ui.input("abc");
  await ui.waitFor(async () => (await cursor())[1] === 3);
  mark = ui.mark();
  await ui.inputMouse("left", "press", pane.row + 1, pane.col + 4);
  await ui.inputMouse("left", "release", pane.row + 1, pane.col + 4);
  await ui.drain();
  await quiet(ui);
  expect(await anvim!.where()).toEqual({ win: "input", mode: "i" });
  expect(await cursor()).toEqual([1, 3]);
  expect(cursorIn(ui.frames(mark), pane)).toEqual([]);

  // A click from read mode keeps it.
  await ui.input("<Esc>");
  await anvim!.waitWhere("input", "n");
  await Bun.sleep(600);
  await ui.input("<Space>cr");
  await anvim!.waitWhere("transcript", "n");
  await ui.inputMouse("left", "press", pane.row + 1, pane.col + 4);
  await ui.inputMouse("left", "release", pane.row + 1, pane.col + 4);
  await ui.drain();
  await quiet(ui);
  expect(await anvim!.where()).toEqual({ win: "transcript", mode: "n" });
  expect(await ui.exec_lua<boolean>(`return vim.w[require("anvim.layout").wins.transcript].anvim_read`)).toBe(true);
});

test("the wheel scrolls the pane from the prompt, and it stops at its end", async () => {
  anvim = await start({ prefs: { tool_pane: true } });
  const { ui } = anvim;
  await ui.exec_lua(`
    local transcript = require("anvim.transcript")
    transcript.user("Many calls")
    for i = 1, 40 do
      transcript.tool_start("w" .. i, "Bash")
      transcript.tool_use({ id = "w" .. i, name = "Bash", input = { command = "echo " .. i } })
    end
  `);
  const pane = await anvim.box("pane");
  await ui.waitFor(() => rows(ui.lines(), pane).some((r) => r.includes("Bash(echo 40)")));
  const last = (lines: string[]) => rows(lines, pane).findIndex((r) => r.includes("Bash(echo 40)"));
  const end = last(ui.lines());
  expect(end).toBe(pane.height - 1);
  for (let i = 0; i < 3; i++) await ui.inputMouse("wheel", "up", pane.row + 2, pane.col + 5);
  await ui.waitFor(() => last(ui.lines()) === -1);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
  const mark = ui.mark();
  for (let i = 0; i < 6; i++) {
    await ui.inputMouse("wheel", "down", pane.row + 2, pane.col + 5);
    await Bun.sleep(30);
  }
  await ui.drain();
  await quiet(ui);
  expect(last(ui.lines())).toBe(end);
  expect(ui.frames(mark).filter((f) => last(f.lines) >= 0 && last(f.lines) < end).length).toBe(0);
});

test("a terminal too short for the pane starts without it, the code window always comes back, and the pane comes with the room", async () => {
  anvim = await start({ prefs: { tool_pane: true }, cols: 80, rows: 6 });
  const { ui } = anvim;
  const errors = () => ui.exec_lua<string>(`return vim.fn.execute("messages") .. vim.v.errmsg`);
  const codeWin = () => ui.exec_lua<number>(`return require("anvim.layout").wins.code`);
  // <C-w>c in the code window, which comes back.
  const closeCode = async () => {
    await anvim!.toCode();
    const closed = await codeWin();
    await ui.input("<C-w>c");
    await ui.waitFor(async () => (await codeWin()) !== closed);
    await anvim!.waitWhere("code", "n");
  };
  const under = async () => {
    const code = await anvim!.box("code");
    const pane = await anvim!.box("pane");
    return pane.col === code.col && pane.width === code.width && pane.row === code.row + code.height + 2;
  };
  expect(await hasPane()).toBe(false);
  await closeCode();
  expect(await hasPane()).toBe(false);

  // Six rows over the statusline: the code window and the pane get a winbar
  // and a row each, and a split with 'cmdheight' 0 needs a row more.
  await ui.resize(80, 7);
  await ui.waitFor(hasPane);
  expect(await under()).toBe(true);
  await closeCode();
  expect(await under()).toBe(true);
  await ui.resize(80, 6);
  await ui.waitFor(async () => !(await hasPane()));
  await closeCode();

  // A tabline takes a row with no resize, and the code window closes before
  // a repair. The column has no room for a split, so the pane gives way.
  await ui.resize(80, 7);
  await ui.waitFor(hasPane);
  const closed = await codeWin();
  await ui.exec_lua(`
    vim.o.showtabline = 2
    vim.api.nvim_win_close(require("anvim.layout").wins.code, true)
  `);
  await ui.waitFor(async () => (await codeWin()) !== closed);
  await quiet(ui);
  expect(await ui.exec_lua<boolean>(`return vim.api.nvim_win_is_valid(require("anvim.layout").wins.code)`)).toBe(true);
  expect(await hasPane()).toBe(false);
  await ui.exec_lua(`vim.o.showtabline = 1`);

  await ui.resize(80, 30);
  await ui.waitFor(hasPane);
  expect(await under()).toBe(true);
  const code = await anvim.box("code");
  const pane = await anvim.box("pane");
  expect(pane.height + 1).toBe(Math.floor((code.height + 2 + pane.height + 1) * 0.25));
  expect(await errors()).not.toMatch(/E\d+:|Error/);
});

test("help, a split and the command line take rows from the column for a while, and the pane stays and gets them back", async () => {
  anvim = await start({ prefs: { tool_pane: true }, cols: 80, rows: 12 });
  const { ui } = anvim;
  await anvim.toCode();
  await quiet(ui);
  const paneWin = () => ui.exec_lua<number>(`return require("anvim.layout").wins.pane`);
  const pane = await paneWin();
  const boxes = async () => ({ code: await anvim!.box("code"), pane: await anvim!.box("pane") });
  const before = await boxes();
  // The command line's window can cover the pane's winbar.
  const shown = (lines: string[]) =>
    lines.some((l) => cells(l, before.code.col, 11) === " Tool calls" || l.includes(" Command line "));
  const mark = ui.mark();

  await ui.input(":help help<CR>");
  await anvim.waitWhere("help", "n");
  await quiet(ui);
  expect((await anvim.box("code")).height).toBeLessThan(before.code.height);
  await ui.input(":q<CR>");
  await anvim.waitWhere("code", "n");
  await quiet(ui);
  expect(await boxes()).toEqual(before);

  await ui.input("<C-w>s");
  await ui.drain();
  await quiet(ui);
  expect(await anvim.where()).toEqual({ win: "code", mode: "n" });
  await ui.input(":echo 1<CR>");
  await ui.drain();
  await quiet(ui);
  expect(await boxes()).toEqual(before);
  // A long command line takes rows while it is open.
  await ui.input(":echo '" + "x".repeat(150));
  await ui.drain();
  await quiet(ui);
  expect(await boxes()).toEqual(before);
  await ui.input("<Esc>");
  await anvim.waitWhere("code", "n");
  expect(await boxes()).toEqual(before);
  expect(await paneWin()).toBe(pane);
  expect(ui.frames(mark).filter((f) => !shown(f.lines)).length).toBe(0);
});

test("a drag, :resize and <C-w>+ give the pane a share that stays through help, a split, the command line and a resize", async () => {
  anvim = await start({ prefs: { tool_pane: true }, cols: 120, rows: 30 });
  const { ui } = anvim;
  const heights = () =>
    ui.exec_lua<[number, number]>(`
      local wins = require("anvim.layout").wins
      return { vim.api.nvim_win_get_height(wins.code), vim.api.nvim_win_get_height(wins.pane) }
    `);
  const [code, pane] = await heights();
  const column = code + 1 + pane;
  const box = await anvim.box("pane");
  const sep = box.row - 2;
  // The separator follows the mouse in each frame.
  const rule = (lines: string[]) => lines.findIndex((l, r) => r > 2 && /^─{10,}/.test(cells(l, box.col, 20)));
  let mark = ui.mark();
  await ui.inputMouse("left", "press", sep, box.col + 10);
  await ui.drain();
  for (let i = 1; i <= 4; i++) {
    await ui.inputMouse("left", "drag", sep - i, box.col + 10);
    await ui.drain();
  }
  await ui.inputMouse("left", "release", sep - 4, box.col + 10);
  await ui.drain();
  await quiet(ui);
  expect(await heights()).toEqual([code - 4, pane + 4]);
  expect([...new Set(ui.frames(mark).map((f) => rule(f.lines)))]).toEqual([sep - 1, sep - 2, sep - 3, sep - 4]);

  await anvim.toCode();
  await ui.input(":resize 10<CR>");
  await ui.waitFor(async () => (await heights())[0] === 10);
  await ui.input("<C-w>+");
  await ui.waitFor(async () => (await heights())[0] === 11);
  const mine: [number, number] = [11, column - 12];
  // A float that closes, such as the Agent Overview, gives no reason to fit.
  await ui.input("<Space>ca");
  await ui.waitFor("Agent Overview");
  await ui.input("q");
  await anvim.waitWhere("code", "n");
  await ui.input("<C-w>-");
  await ui.waitFor(async () => (await heights())[0] === 10);
  await ui.input("<C-w>+");
  await ui.waitFor(async () => (await heights())[0] === 11);

  mark = ui.mark();
  await ui.input(":help help<CR>");
  await anvim.waitWhere("help", "n");
  await ui.input(":q<CR>");
  await anvim.waitWhere("code", "n");
  await quiet(ui);
  expect(await heights()).toEqual(mine);
  await ui.input("<C-w>s");
  await ui.drain();
  await quiet(ui);
  expect(await heights()).toEqual(mine);
  await ui.input(":echo 1<CR>");
  await ui.drain();
  await quiet(ui);
  expect(await heights()).toEqual(mine);
  // A long command line takes rows while it is open.
  await ui.input(":echo '" + "x".repeat(250));
  await ui.drain();
  await quiet(ui);
  expect(await heights()).toEqual(mine);
  await ui.input("<Esc>");
  await anvim.waitWhere("code", "n");
  expect(await heights()).toEqual(mine);

  // A resize keeps the share.
  await ui.resize(120, 20);
  await ui.waitFor(async () => (await heights())[0] < 11);
  await quiet(ui);
  const [small, smallPane] = await heights();
  expect(smallPane).toBe(Math.floor(((small + 1 + smallPane) * mine[1]) / column + 1e-6));
  await ui.resize(120, 30);
  await ui.waitFor(async () => (await heights())[0] === 11);
  await quiet(ui);
  expect(await heights()).toEqual(mine);
});

// Plays the overview session fast, and holds it a minute before the first
// agent's text, so that its three agents still run.
const holdAgents = (frames: string[]) => {
  let at = 0;
  let prev: number | null = null;
  let held = false;
  return frames.map((line) => {
    const space = line.indexOf(" ");
    const t = Number(line.slice(0, space));
    const rest = line.slice(space + 1);
    let gap = prev === null ? 0 : Math.min(t - prev, 30);
    if (!held && JSON.parse(rest).type === "agent_text") {
      gap = 60000;
      held = true;
    }
    prev = t;
    at += gap;
    return `${at} ${rest}`;
  });
};

test("<leader>c1 shows the subagent's tool calls in the pane, under its name in its color, and <leader>c0 Claude's", async () => {
  const files = {
    "alpha.js": "// Adds two numbers.\nfunction add(a, b) {\n  return a + b;\n}\n",
    "beta.js": "// Greets a person by name.\nfunction greet(name) {\n  return 'Hello, ' + name;\n}\n",
    "gamma.js": "// Keeps the first n items of a list.\nfunction take(list, n) {\n  return list.slice(0, n);\n}\n",
  };
  anvim = await start({
    recording: "overview-session.jsonl",
    files,
    frames: holdAgents,
    env: { ANVIM_REPLAY_SPEED: "1" },
    prefs: { tool_pane: true },
  });
  const { ui } = anvim;
  await send("List the functions");
  await ui.waitFor(() =>
    ui.exec_lua<boolean>(`
      local a = require("anvim.agents").in_slot(1)
      return #require("anvim.agents").running() == 3 and a and a.activity == "Reading alpha.js"
    `),
  );
  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  const pane = await anvim.box("pane");
  const winbar = () => cells(ui.lines()[pane.row - 1]!, pane.col, 24).trimEnd();
  expect(winbar()).toBe(" Tool calls");
  expect(rows(ui.lines(), pane).some((r) => r.includes("⏺ Agent(List functions in alpha.js)"))).toBe(true);

  const mark = ui.mark();
  await ui.input("<Space>c1");
  await ui.waitFor(() => winbar() === " Tool calls · Agent 1");
  // ext_hlstate names the group that a link ends in.
  const agent1 = await ui.exec_lua<string>(`
    local name = "AnvimAgent1"
    while vim.api.nvim_get_hl(0, { name = name }).link do
      name = vim.api.nvim_get_hl(0, { name = name }).link
    end
    return name
  `);
  expect(hlNames(pane.row - 1, pane.col + 14)).toContain(agent1);
  await ui.waitFor(() => rows(ui.lines(), pane).some((r) => r.includes("⏺ Read(alpha.js)")));
  expect(rows(ui.lines(), pane).some((r) => r.includes("⏺ Agent("))).toBe(false);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
  // No frame shows the new name over the old log, or the old name over the new one.
  const mixed = ui.frames(mark).filter((f) => {
    const bar = cells(f.lines[pane.row - 1]!, pane.col, 24).trimEnd();
    const main = rows(f.lines, pane).some((r) => r.includes("⏺ Agent("));
    return (bar === " Tool calls · Agent 1") === main;
  });
  expect(mixed.length).toBe(0);

  await ui.input("<Space>c0");
  await ui.waitFor(() => winbar() === " Tool calls");
  expect(rows(ui.lines(), pane).some((r) => r.includes("⏺ Agent(List functions in alpha.js)"))).toBe(true);
});

test("the explorer's toggle, <leader>uH and the Agent Overview keep the pane under the code window", async () => {
  const { ui } = await editTurn();
  const boxes = async () => ({ code: await anvim!.box("code"), pane: await anvim!.box("pane") });
  const right = await boxes();
  const under = (b: Awaited<ReturnType<typeof boxes>>) =>
    b.pane.col === b.code.col && b.pane.width === b.code.width && b.pane.row === b.code.row + b.code.height + 2;
  expect(under(right)).toBe(true);
  // At the tree's edge, the code window's separator row and the pane's
  // winbar row show the tree's wall in the same frames.
  const wall = right.code.col - 1;
  const torn = (lines: string[]) =>
    ([...lines[right.pane.row - 2]!][wall] === "─") !== ([...lines[right.pane.row - 1]!][wall] !== "│");

  let mark = ui.mark();
  await ui.input("<Space>e");
  await ui.waitFor(async () => (await anvim!.box("code")).col === 0);
  await quiet(ui);
  const wide = await boxes();
  expect(under(wide)).toBe(true);
  expect(wide.pane.width).toBe(right.pane.width + right.code.col);
  expect(wide.pane.height).toBe(right.pane.height);
  expect(ui.frames(mark).filter((f) => torn(f.lines)).length).toBe(0);

  mark = ui.mark();
  await ui.input("<Space>e");
  await anvim!.waitWhere("snacks_picker_list", "n");
  await ui.waitFor(async () => (await anvim!.box("code")).col === right.code.col);
  await quiet(ui);
  expect(await boxes()).toEqual(right);
  expect(ui.frames(mark).filter((f) => torn(f.lines)).length).toBe(0);
  await ui.input("<C-l>");
  await anvim!.waitWhere("code", "n");

  await ui.input("<Space>uH");
  await ui.waitFor(async () => (await anvim!.box("transcript")).col === 0);
  await quiet(ui);
  const left = await boxes();
  expect(under(left)).toBe(true);
  expect(left.pane).toEqual({ ...right.pane, col: (await anvim!.box("transcript")).width + 1 });
  await ui.input("<Space>uH");
  await ui.waitFor(async () => (await anvim!.box("tree")).col === 0);
  await quiet(ui);
  expect(await boxes()).toEqual(right);

  await ui.input("<Space>ca");
  await ui.waitFor("Agent Overview");
  expect(await boxes()).toEqual(right);
  await ui.input("q");
  await ui.waitFor(async () => !ui.screen().includes("Agent Overview"));
  await quiet(ui);
  expect(await boxes()).toEqual(right);
  expect(await hasPane()).toBe(true);

  // <C-w>c in the code window gives its rows to the pane for a moment, and
  // no frame shows that.
  const codeWin = () => ui.exec_lua<number>(`return require("anvim.layout").wins.code`);
  await anvim!.toCode();
  const closed = await codeWin();
  mark = ui.mark();
  await ui.input("<C-w>c");
  await ui.waitFor(async () => (await codeWin()) !== closed);
  await anvim!.waitWhere("code", "n");
  await quiet(ui);
  expect(await boxes()).toEqual(right);
  const rule = (lines: string[]) => /^─+$/.test(cells(lines[right.pane.row - 2]!, right.code.col, right.code.width));
  expect(ui.frames(mark).filter((f) => !rule(f.lines)).length).toBe(0);

  // A resize keeps the pane at a quarter of the column.
  await ui.resize(160, 40);
  await ui.waitFor(async () => (await anvim!.box("code")).width < right.code.width);
  await quiet(ui);
  const small = await boxes();
  expect(under(small)).toBe(true);
  const column = small.code.height + 2 + small.pane.height + 1;
  expect(small.pane.height + 1).toBe(Math.floor(column * 0.25));
  await ui.resize(200, 48);
  await ui.waitFor(async () => (await anvim!.box("code")).width === right.code.width);
  await quiet(ui);
  expect(await boxes()).toEqual(right);
});
