// The completion menus as Neovim draws them: after @ and / in the prompt with
// the first item highlighted, and on the command line with no item highlighted.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

type Flush = { menu: boolean; selected: boolean; text: string };

// What each flush shows: the menu, a highlighted item in it, and the screen.
function watch(a: Anvim): Flush[] {
  const seen: Flush[] = [];
  a.ui.onFlush = () => {
    let menu = false;
    let selected = false;
    for (const row of a.ui.grid) {
      for (const cell of row) {
        const names = (a.ui.attrs.get(cell.hl)?.names ?? "").split("+");
        menu ||= names.includes("Pmenu");
        selected ||= names.includes("PmenuSel");
      }
    }
    seen.push({ menu, selected, text: a.ui.screen() });
  };
  return seen;
}

// The menu's item rows on the grid, as text, and the rows that are highlighted.
// With a border, pum_getpos() gives the row of its top edge and the number of
// items.
async function menu(a: Anvim) {
  const pos = await a.ui.exec_lua<{ row?: number; col: number; height: number; width: number }>(
    `return vim.fn.pum_getpos()`,
  );
  if (pos.row === undefined) return { rows: [] as string[], selected: [] as number[] };
  const rows: string[] = [];
  const selected: number[] = [];
  for (let r = pos.row; r < pos.row + pos.height + 2; r++) {
    const cells = a.ui.grid[r]!.slice(pos.col, pos.col + pos.width);
    const text = cells.map((c) => c.text).join("");
    if (/^[─╭╮╰╯\s]*$/.test(text)) continue;
    if (cells.some((c) => (a.ui.attrs.get(c.hl)?.names ?? "").split("+").includes("PmenuSel"))) {
      selected.push(rows.length);
    }
    rows.push(text);
  }
  return { rows, selected };
}

const selected = (a: Anvim) => a.ui.exec_lua<number>(`return vim.fn.complete_info({ "selected" }).selected`);

function noErrors(seen: Flush[]) {
  expect(seen.filter((f) => /E\d+:|Error|stack traceback/.test(f.text)).map((f) => f.text)).toEqual([]);
}

test("@ and / open a menu in the prompt with its first item highlighted, in every frame", async () => {
  anvim = await start({ files: { "lua/anvim/stream.lua": "return 1\n" } });
  const { ui } = anvim;
  const seen = watch(anvim);
  await anvim.insert();
  await anvim.type("see @");
  await ui.waitFor(async () => (await selected(anvim!)) === 0);
  await ui.drain();
  let shown = await menu(anvim);
  // Shallow paths first.
  expect(shown.rows[0]).toContain("matchparen.lua");
  expect(shown.rows.some((row) => row.includes("lua/anvim/stream.lua"))).toBe(true);
  expect(shown.selected).toEqual([0]);

  await anvim.type("stre");
  await ui.waitFor(async () => (await menu(anvim!)).rows[0]?.includes("lua/anvim/stream.lua"));
  expect((await menu(anvim)).selected).toEqual([0]);
  await anvim.hideMenu();
  await ui.exec_lua(`vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })`);

  await ui.exec_lua(`require("anvim.sidecar").dispatch({ type = "commands", commands = {
    { name = "compact", description = "Clear conversation history but keep a summary in context" },
    { name = "context", description = "Visualize current context usage" },
  } })`);
  await anvim.type("/co");
  await ui.waitFor(async () => (await selected(anvim!)) === 0);
  await ui.drain();
  shown = await menu(anvim);
  expect(shown.rows[0]).toContain("/compact");
  expect(shown.rows[0]).toContain("Clear conversation");
  expect(shown.rows[1]).toContain("/context");
  expect(shown.selected).toEqual([0]);
  await anvim.hideMenu();

  // Neovim highlights the item from the event loop, before it draws the menu.
  expect(seen.some((f) => f.menu)).toBe(true);
  expect(seen.filter((f) => f.menu && !f.selected).length).toBe(0);
  noErrors(seen);
  expect(await ui.exec_lua(`return vim.v.errmsg`)).toBe("");
});

test("the command line shows a menu as a command is typed, with no item highlighted, and none for a search", async () => {
  anvim = await start();
  const { ui } = anvim;
  const seen = watch(anvim);
  await anvim.waitWhere("input", "n");
  await ui.input(":");
  await anvim.type("setl");
  await ui.waitFor(async () => (await menu(anvim!)).rows.some((row) => row.includes("setlocal")));
  expect((await menu(anvim)).selected).toEqual([]);
  // <Up> goes back through the command history while the menu shows.
  await ui.input("<Esc>");
  await ui.input(":lua vim.g.anvim_probe = 1<CR>");
  await ui.input(":");
  await anvim.type("lua");
  await ui.waitFor(async () => (await menu(anvim!)).rows.length > 0);
  await ui.input("<Up>");
  // The command line is in its window over the code, inside the border.
  await ui.waitFor(() => ui.lines().some((line) => line.includes("│:lua vim.g.anvim_probe = 1")));
  await ui.input("<Esc>");

  await ui.input("/");
  await anvim.type("setl");
  await Bun.sleep(300);
  await ui.drain();
  expect((await menu(anvim)).rows).toEqual([]);
  await ui.input("<Esc>");
  noErrors(seen);
});

// The menu as complete_info() and the prompt see it.
const state = (a: Anvim) =>
  a.ui.exec_lua<{ pum: number; selected: number; words: string[]; lines: string[] }>(`
    local info = vim.fn.complete_info({ "selected", "items" })
    return {
      pum = vim.fn.pumvisible(),
      selected = info.selected,
      words = vim.tbl_map(function(item) return item.word end, info.items),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    }
  `);

// Starts typing in the prompt while the code window shows matchparen.lua,
// whose words the menu offers.
async function words(a: Anvim) {
  await a.toCode();
  await a.ui.exec_lua(`require("anvim.layout").focus_input({ insert = false })`);
  await a.insert();
}

test("a word menu highlights nothing, so Enter sends; <C-n> and <C-p> move the highlight, and Enter then takes the word", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await words(anvim);
  await anvim.type("see matchp");
  await ui.waitFor(async () => (await state(anvim!)).pum === 1);
  let got = await state(anvim);
  expect(got.selected).toBe(-1);
  expect(got.words.length).toBeGreaterThan(2);
  const first = got.words[0]!;
  await ui.input("<C-n>");
  await ui.drain();
  got = await state(anvim);
  expect([got.pum, got.selected]).toEqual([1, 0]);
  await ui.input("<C-n>");
  await ui.drain();
  expect((await state(anvim)).selected).toBe(1);
  await ui.input("<C-p>");
  await ui.drain();
  got = await state(anvim);
  expect([got.pum, got.selected]).toEqual([1, 0]);
  await ui.input("<CR>");
  await ui.drain();
  got = await state(anvim);
  expect([got.pum, got.lines]).toEqual([0, [`see ${first}`]]);
  const sent = () => ui.exec_lua<string[]>(`return vim.tbl_map(function(m) return m.text end, _G.anvim_sent)`);
  expect(await sent()).toEqual([]);

  await anvim.type(" and matchp");
  await ui.waitFor(async () => (await state(anvim!)).pum === 1);
  expect((await state(anvim)).selected).toBe(-1);
  await ui.input("<CR>");
  await ui.waitFor(async () => (await sent()).length > 0);
  expect(await sent()).toEqual([`see ${first} and matchp`]);
  got = await state(anvim);
  expect([got.pum, got.lines]).toEqual([0, [""]]);
});

test("<S-CR> and <M-CR> make a new line while the menu shows", async () => {
  anvim = await start();
  const { ui } = anvim;
  await words(anvim);
  await anvim.type("see matchp");
  await ui.waitFor(async () => (await state(anvim!)).pum === 1);
  await ui.input("<S-CR>");
  await ui.drain();
  expect((await state(anvim)).lines).toEqual(["see matchp", ""]);
  await anvim.type("and @matchp");
  await ui.waitFor(async () => (await state(anvim!)).selected === 0);
  await ui.input("<M-CR>");
  await ui.drain();
  const got = await state(anvim);
  expect([got.pum, got.lines]).toEqual([0, ["see matchp", "and @matchp", ""]]);
});

test("a backspace keeps the @ menu open and widens it", async () => {
  anvim = await start({ files: { "lua/anvim/stream.lua": "return 1\n", "lua/anvim/state.lua": "return 2\n" } });
  const { ui } = anvim;
  await anvim.insert();
  await anvim.type("see @lua/anvim/str");
  await ui.waitFor(async () => (await state(anvim!)).words.join() === "@lua/anvim/stream.lua ");
  await ui.input("<BS>");
  await ui.input("<BS>");
  await ui.drain();
  const got = await state(anvim);
  expect(got.pum).toBe(1);
  expect(got.selected).toBe(0);
  expect(got.words).toContain("@lua/anvim/state.lua ");
});

test("the menu gets at most 200 items, and a file past them comes up by name", async () => {
  const files: Record<string, string> = { "deep/a/b/c/needle.md": "x\n" };
  // Each of them matches "needle" too, but worse, and comes first in the list.
  for (let i = 0; i < 300; i++) files[`n_e_e_d_l_e_${String(i).padStart(3, "0")}.txt`] = "x\n";
  anvim = await start({ files });
  const { ui } = anvim;
  await anvim.insert();
  await anvim.type("@");
  await ui.waitFor(async () => (await state(anvim!)).pum === 1);
  let got = await state(anvim);
  expect(got.words.length).toBe(200);
  expect(got.words).not.toContain("@deep/a/b/c/needle.md ");
  await anvim.type("needle");
  await ui.waitFor(async () => (await state(anvim!)).words[0] === "@deep/a/b/c/needle.md ");
  got = await state(anvim);
  expect(got.selected).toBe(0);
});
