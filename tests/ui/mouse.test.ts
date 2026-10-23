import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// The character under the cursor in the current window.
const under = () =>
  anvim!.ui.exec_lua<string>(`
    local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2]
    return line:sub(col + 1, col + 1)
  `);

test("a click from insert mode in the prompt ends insert mode in read-only windows, and a picker keeps it", async () => {
  anvim = await start();
  const { ui } = anvim;
  const click = async (box: Box, row: number, col: number) => {
    await ui.inputMouse("left", "press", box.row + row, box.col + col);
    await ui.inputMouse("left", "release", box.row + row, box.col + col);
  };
  const cursor = () => ui.exec_lua<[number, number]>(`return vim.api.nvim_win_get_cursor(0)`);
  const notNormal = (since: number) => ui.frames(since).flatMap((f) => (f.mode === "normal" ? [] : [f.mode]));
  await anvim.toCode();
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  const code = await anvim.box("code");
  await ui.drain();
  const clicked = ui.grid[code.row + 2]![code.col + 14]!.text;
  expect(clicked).not.toBe(" ");

  // A click from normal mode lands on the character under the mouse.
  await click(code, 2, 14);
  await anvim.waitWhere("code", "n");
  const want = await cursor();
  expect(await under()).toBe(clicked);
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  // Past 'mousetime', so the next click is no double click.
  await Bun.sleep(600);

  await anvim.insert();
  await anvim.type("hello");
  await ui.drain();
  let mark = ui.mark();
  await click(code, 2, 14);
  await anvim.waitWhere("code", "n");
  await ui.waitFor(() => inBox(ui.cursor, code));
  expect(ui.frames(mark).length).toBeGreaterThan(0);
  expect(notNormal(mark)).toEqual([]);
  // Like <Esc>, the end of insert mode would move the cursor one left.
  expect(await cursor()).toEqual(want);

  // An insert command types in the prompt again.
  await ui.input("i");
  await anvim.waitWhere("input", "i");
  await anvim.type("!");
  expect(await ui.exec_lua<string>(`return vim.api.nvim_get_current_line()`)).toBe("hello!");

  const tree = await anvim.box("tree");
  await ui.drain();
  mark = ui.mark();
  await click(tree, 1, 4);
  await anvim.waitWhere("snacks_picker_list", "n");
  expect(notNormal(mark)).toEqual([]);

  // A picker's input opens in insert mode, also from insert mode in the prompt.
  await ui.exec_lua(`require("anvim.layout").focus_input()`);
  await anvim.waitWhere("input", "i");
  await ui.input("<Cmd>lua Snacks.picker.files()<CR>");
  await anvim.waitWhere("snacks_picker_input", "i");
  await anvim.type("match");
  expect(await ui.exec_lua(`return vim.api.nvim_get_current_line()`)).toContain("match");
  await ui.input("<C-c>");
  await anvim.waitWhere("input", "n");
  // snacks takes a closed picker down two scheduled turns later, and runs
  // :stopinsert again then, in the window that has the cursor.
  await ui.exec_lua(`
    local done = false
    vim.schedule(function() vim.schedule(function() done = true end) end)
    vim.wait(1000, function() return done end)
  `);
  // The tree's click and the picker left the prompt in insert mode. Typing goes on at its end.
  await ui.input("i");
  await anvim.waitWhere("input", "i");
  await anvim.type("x");
  expect(await ui.exec_lua<string>(`return vim.api.nvim_get_current_line()`)).toBe("hello!x");
});

test("after insert mode ends in another window, a reference and the compose window go on where typing stopped", async () => {
  anvim = await start();
  const { ui } = anvim;
  const prompt = () => ui.exec_lua<string>(`return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, 1, false)[1]`);
  await anvim.toCode();
  const code = await anvim.box("code");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");

  // <Esc> sets the `^` mark after "hello". Typing starts again before the "o",
  // and an API call ends it in the code window.
  await anvim.insert();
  await anvim.type("hello");
  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  await anvim.insert();
  await ui.input(`<Cmd>lua vim.api.nvim_set_current_win(require("anvim.layout").wins.code)<CR>`);
  await anvim.waitWhere("code", "n");
  await ui.input("cc");
  await anvim.waitWhere("input", "i");
  await anvim.type("x");
  expect(await prompt()).toMatch(/^hell @matchparen\.lua#L\d+ xo$/);

  // A click ends insert mode in the compose window.
  await ui.input("<C-g>");
  await anvim.waitWhere("anvim_input", "i");
  await anvim.type("y");
  await ui.inputMouse("left", "press", code.row + 1, code.col + 14);
  await ui.inputMouse("left", "release", code.row + 1, code.col + 14);
  await anvim.waitWhere("code", "n");
  await ui.waitFor(() => ui.exec_lua<boolean>(`return require("anvim.compose").win() == nil`));
  expect(await prompt()).toMatch(/^hell @matchparen\.lua#L\d+ xyo$/);
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await anvim.insert();
  await anvim.type("z");
  expect(await prompt()).toMatch(/^hell @matchparen\.lua#L\d+ xyzo$/);
});

test("a click from the prompt on a wrapped line's second screen row lands on the character under the mouse", async () => {
  const long = Array.from({ length: 60 }, (_, i) => `word${i}`).join(" ");
  anvim = await start({ files: { "doc.md": `# Title\n\n${long}\n\nshort line\n` } });
  const { ui } = anvim;
  await anvim.toCode("doc.md", { lnum: 1, topline: 1 });
  const code = await anvim.box("code");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.drain();
  // Row 3 is the long line's second screen row.
  const [row, col] = [code.row + 3, code.col + 30];
  const clicked = ui.grid[row]![col]!.text;
  expect(clicked).not.toBe(" ");
  await ui.inputMouse("left", "press", row, col);
  await ui.inputMouse("left", "release", row, col);
  await anvim.waitWhere("code", "n");
  await ui.drain();
  expect(await under()).toBe(clicked);
  expect(ui.cursor).toEqual({ row, col });
});

test("a click on the code window's gutter from the prompt goes to that line, as in review mode's number column", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode("matchparen.lua", { lnum: 20, topline: 10 });
  const code = await anvim.box("code");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  const promptCursor = `return vim.api.nvim_win_get_cursor(require("anvim.layout").wins.input)`;
  await ui.exec_lua(`
    local win = require("anvim.layout").wins.input
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { "first line", "second line", "third line" })
    vim.api.nvim_win_set_cursor(win, { 2, 3 })
  `);
  const top = await ui.exec_lua<number>(`return vim.fn.line("w0", require("anvim.layout").wins.code)`);
  await ui.inputMouse("left", "press", code.row + 3, code.col + 1);
  await ui.inputMouse("left", "release", code.row + 3, code.col + 1);
  await anvim.waitWhere("code", "n");
  expect(await ui.exec_lua(`return vim.api.nvim_win_get_cursor(0)`)).toEqual([top + 3, 0]);
  // Neovim moved the prompt's cursor for the click. It is back, so typing goes on there.
  expect(await ui.exec_lua(promptCursor)).toEqual([2, 3]);
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await anvim.insert();
  await anvim.type("!");
  expect(await ui.exec_lua(`return vim.api.nvim_get_current_line()`)).toBe("sec!ond line");
});

test("a click from the prompt lands on the character under the mouse after the file grew past 999 lines while following", async () => {
  const short = Array.from({ length: 5 }, (_, i) => `local short${i + 1} = ${i + 1}`).join("\n");
  anvim = await start({ files: { "short.lua": `${short}\n` } });
  const { ui } = anvim;
  const textoff = () => ui.exec_lua<number>(`return vim.fn.getwininfo(require("anvim.layout").wins.code)[1].textoff`);
  await anvim.toCode("short.lua");
  const review = await textoff();
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.drain();
  expect(await textoff()).toBe(review);
  // Lines arrive while following, as in a preview, and the gutter keeps its width.
  await ui.exec_lua(`
    local buf = vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)
    local lines = {}
    for i = 6, 1005 do
      lines[#lines + 1] = ("local short%d = %d"):format(i, i)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  `);
  await ui.waitFor("local short12 = 12");
  await ui.drain();
  const code = await anvim.box("code");
  const following = await textoff();
  expect(following).toBe(review);
  const col = following + "local short".length;
  expect(ui.grid[code.row + 1]![code.col + col]!.text).toBe("2");
  await ui.inputMouse("left", "press", code.row + 1, code.col + col);
  await ui.inputMouse("left", "release", code.row + 1, code.col + col);
  await anvim.waitWhere("code", "n");
  await ui.drain();
  // Review mode's numbers need a fourth digit now.
  expect(await textoff()).toBe(following + 1);
  expect(await ui.exec_lua(`return vim.api.nvim_win_get_cursor(0)`)).toEqual([2, "local short".length]);
});
