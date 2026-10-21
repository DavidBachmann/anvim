// Follow mode hides the code window's line numbers, so a Write preview that
// grows past 9 lines never pushes its text to the right. Review mode shows
// them, and the switch shows in the frame of the cursor's move.
import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, type Box, cells, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const FIRST = "-- Counts the words in a buffer.";

// Where the frame shows the preview's text: the column of its first line in
// the code window, and whether the cells left of the text hold a number.
function look(f: Frame, box: Box): { col: number; numbers: boolean } | null {
  const rows = f.lines.slice(box.row, box.row + box.height).map((l) => cells(l, box.col, box.width));
  const first = rows.find((r) => r.includes(FIRST));
  if (!first) return null;
  const col = [...first.slice(0, first.indexOf(FIRST))].length;
  return { col, numbers: rows.some((r) => /\d/.test(cells(r, 0, col))) };
}

// The mode block at the left of the global statusline.
const block = (f: Frame, row: number) => (f.lines[row] ?? "").trim().split(" ")[0];

test("a Write preview that grows past 9 lines keeps its text in place while following, and review shows the numbers at once", async () => {
  anvim = await start({ recording: "write-session.jsonl", env: { ANVIM_REPLAY_SPEED: "1" } });
  const { ui } = anvim;
  const code = await anvim.box("code");
  const statusline = await ui.exec_lua<number>(`return vim.o.lines - vim.o.cmdheight - 1`);
  const mark = ui.mark();
  await ui.exec_lua(`require("anvim.input").send("Write made.lua")`);
  await ui.waitFor(() =>
    ui.exec_lua<boolean>(`
      local buf = vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)
      return vim.b[buf].anvim_preview ~= nil and vim.api.nvim_buf_line_count(buf) >= 14
    `),
  );
  const move = ui.mark();
  await ui.input("<C-w>h");
  await anvim.waitWhere("code", "n");
  await Bun.sleep(300);
  await ui.drain();
  const back = ui.mark();
  await ui.input("<C-w>l");
  await anvim.waitWhere("input", "n");
  await Bun.sleep(100);
  await ui.drain();

  const following = ui.frames(mark).slice(0, move - mark).flatMap((f) => look(f, code) ?? []);
  expect(following.length).toBeGreaterThan(5);
  expect(following.filter((l) => l.numbers)).toEqual([]);
  expect(new Set(following.map((l) => l.col)).size).toBe(1);

  // From the move on, a frame shows the numbers and NORMAL exactly while the
  // cursor is in the code window.
  const states = ui.frames(move).flatMap((f) => {
    const l = look(f, code);
    return l ? [{ review: inBox(f.cursor, code), numbers: l.numbers, block: block(f, statusline), col: l.col }] : [];
  });
  const review = states.filter((s) => s.review);
  expect(review.length).toBeGreaterThan(0);
  expect(review[0]!.col).toBeGreaterThan(following[0]!.col);
  expect(states.filter((s) => s.numbers !== s.review)).toEqual([]);
  expect(states.filter((s) => (s.block === "NORMAL") !== s.review)).toEqual([]);
  expect(states.filter((s) => !s.review).every((s) => s.block === "FOLLOW" && s.col === following[0]!.col)).toBe(true);
  // The states above cover the way back too.
  expect(ui.frames(back).some((f) => look(f, code) && !inBox(f.cursor, code))).toBe(true);
  expect(look(ui.frames().at(-1)!, code)?.numbers).toBe(false);
});

// snacks builds the explorer's split again on a resize, inside
// nvim_win_call(), so the cursor enters the split and goes back without
// autocmds.
test("follow mode stays while a terminal resize builds the explorer again", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    _G.anvim_modes = 0
    vim.api.nvim_create_autocmd("User", { pattern = "AnvimMode", callback = function() _G.anvim_modes = _G.anvim_modes + 1 end })
    local path = ...
    require("anvim.follow").show(vim.fn.bufadd(path), 1)
  `, `${anvim.dir}/matchparen.lua`);
  await ui.waitFor("local api = vim.api");
  const mark = ui.mark();
  for (const [cols, rows] of [[180, 44], [200, 48]] as const) {
    await ui.resize(cols, rows);
    await ui.waitFor(() => ui.lines().length === rows && (ui.lines()[0] ?? "").length >= cols);
    await Bun.sleep(300);
    await ui.drain();
  }
  await anvim.waitWhere("input", "n");
  expect(await ui.exec_lua(`return { require("anvim.follow").mode(), _G.anvim_modes }`)).toEqual(["follow", 0]);
  const code = await anvim.box("code");
  const shown = ui.frames(mark).filter((f) => f.lines.length === 48 && f.lines.some((l) => l.includes("local api = vim.api")));
  expect(shown.length).toBeGreaterThan(0);
  const numbered = shown.filter((f) =>
    f.lines.slice(code.row, code.row + code.height).some((l) => /^\s*\d+\s+local api = vim\.api/.test(cells(l, code.col, code.width))),
  );
  expect(numbered.length).toBe(0);
});

// A move without autocmds, such as a plugin's `noautocmd wincmd p`, fires no
// WinEnter. SafeState comes before the redraw and sets the mode.
test("a move to the code window without autocmds shows the numbers in its first frame", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(
    `
    local path = ...
    require("anvim.follow").show(vim.fn.bufadd(path), 1)
    vim.keymap.set("n", "<F2>", function()
      vim.cmd("noautocmd call nvim_set_current_win(" .. require("anvim.layout").wins.code .. ")")
    end)
  `,
    `${anvim.dir}/matchparen.lua`,
  );
  await ui.waitFor("local api = vim.api");
  const code = await anvim.box("code");
  const mark = ui.mark();
  await ui.input("<F2>");
  await anvim.waitWhere("code", "n");
  await ui.drain();
  const moved = ui.frames(mark).filter((f) => inBox(f.cursor, code));
  expect(moved.length).toBeGreaterThan(0);
  const first = moved[0]!.lines.slice(code.row, code.row + code.height).map((l) => cells(l, code.col, code.width));
  expect(first.some((l) => /^\s*\d+\s+local api = vim\.api/.test(l))).toBe(true);
  expect(await ui.exec_lua(`return require("anvim.follow").mode()`)).toBe("review");
});

// Rows of the code window that show a line number, and rows whose code starts
// right after the sign columns, as in follow mode.
function gutter(f: Frame, code: Box) {
  const rows = f.lines.slice(code.row, code.row + code.height).map((l) => cells(l, code.col, code.width));
  return {
    numbered: rows.filter((r) => /^\s{0,4}\d+\s+\S/.test(r)).length,
    bare: rows.filter((r) => /^ {4}(local|---|return|end|if|for|M\.)/.test(r)).length,
  };
}

test("the mode block and the line numbers change in the same frame, for each way in and out of follow mode", async () => {
  anvim = await start({ files: { "other.lua": "local other = 1\nreturn other\n" } });
  const { ui } = anvim;
  const statusline = await ui.exec_lua<number>(`return vim.o.lines - vim.o.cmdheight - 1`);
  await anvim.toCode("matchparen.lua", { lnum: 20, topline: 10 });
  const code = await anvim.box("code");
  // Each step ends in a window and a mode, and no frame on the way shows
  // FOLLOW with numbers, or another mode's block with bare code.
  const step = async (name: string, keys: string[], win: string, mode: string, wait = 600) => {
    const mark = ui.mark();
    for (const k of keys) {
      await ui.input(k);
      await Bun.sleep(40);
    }
    await anvim!.waitWhere(win, mode);
    await Bun.sleep(wait);
    await ui.drain();
    const bad = ui.frames(mark).flatMap((f, i) => {
      const shown = block(f, statusline);
      const { numbered, bare } = gutter(f, code);
      const wrong =
        (shown === "FOLLOW" && numbered > 0) || (shown !== "FOLLOW" && shown !== "" && bare > 0 && numbered === 0);
      return wrong ? [`${name} #${i}: ${shown}, ${numbered} numbered, ${bare} bare`] : [];
    });
    expect(bad).toEqual([]);
  };
  const click = (action: string) => `<Left${action}><${code.col + 20},${code.row + 5}>`;
  await step("to the prompt", ["<C-w>l"], "input", "n");
  await step("back to the code window", ["<C-w>h"], "code", "n");
  await step("pin", ["V2j<Esc>"], "code", "n");
  await step("to the prompt with a pin", ["<C-w>l"], "input", "n");
  await step("unpin", ["<C-x>"], "input", "n");
  await step("compose window", ["<C-g>"], "anvim_input", "n");
  await step("compose window closes", ["<C-g>"], "input", "n");
  await step("key view", ["?"], "anvim_keys", "n");
  await step("key view closes", ["q"], "input", "n");
  await step("picker", [" ", " "], "snacks_picker_input", "i", 900);
  await step("picker confirms into the code window", ["matchparen", "<CR>"], "code", "n", 800);
  await step("to the prompt again", ["<C-w>l"], "input", "n");
  // The mode changes in the explorer's list, a float, where lualine writes
  // only the float's statusline.
  await step("explorer", [" ", "e"], "snacks_picker_list", "n", 900);
  await step("click into the code window", [click("Mouse"), click("Release")], "code", "n");
  await step("to the prompt from the code window", ["<C-w>l"], "input", "n");
  await step("explorer again", [" ", "e"], "snacks_picker_list", "n", 900);
  await step("open a file from the explorer", ["G", "<CR>"], "code", "n", 800);
  expect(await ui.exec_lua(`return vim.fn.expand("%:t")`)).toBe("other.lua");
});

test("a :set of the numbers in review mode stays until the mode changes", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode("matchparen.lua");
  const numbers = `local w = require("anvim.layout").wins.code return { vim.wo[w].number, vim.wo[w].relativenumber }`;
  await ui.input(":set nonumber norelativenumber<CR>");
  await ui.input("jjk");
  await Bun.sleep(200);
  await ui.drain();
  expect(await ui.exec_lua(numbers)).toEqual([false, false]);
  await ui.input("<C-w>l");
  await anvim.waitWhere("input", "n");
  await ui.input("<C-w>h");
  await anvim.waitWhere("code", "n");
  expect(await ui.exec_lua(numbers)).toEqual([true, true]);
});
