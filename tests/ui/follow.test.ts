// Follow mode hides the code window's line numbers, so a Write preview that
// grows past 9 lines never pushes its text to the right. Review mode shows
// them, and the switch shows in the frame of the cursor's move.
import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, type Box, cells, inBox, quiet, start } from "./helpers.ts";

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
  // The preview grew past 9 lines while following, so review's numbers need
  // one more column.
  expect(review[0]!.col).toBeGreaterThan(following[0]!.col);
  expect(states.filter((s) => s.numbers !== s.review)).toEqual([]);
  expect(states.filter((s) => (s.block === "NORMAL") !== s.review)).toEqual([]);
  expect(states.filter((s) => !s.review).every((s) => s.block === "FOLLOW")).toBe(true);
  // On the way back, follow mode takes the review gutter's width.
  const cols = ui.frames(back).flatMap((f) => look(f, code)?.col ?? []);
  expect([...new Set(cols)]).toEqual([review.at(-1)!.col]);
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
// right after blank columns, as in follow mode.
function gutter(f: Frame, code: Box) {
  const rows = f.lines.slice(code.row, code.row + code.height).map((l) => cells(l, code.col, code.width));
  return {
    numbered: rows.filter((r) => /^\s{0,4}\d+\s+\S/.test(r)).length,
    bare: rows.filter((r) => /^ +(local|---|return|end|if|for|M\.)/.test(r)).length,
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
  const step = async (name: string, keys: string[], win: string, mode: string, wait = 150) => {
    const mark = ui.mark();
    for (const k of keys) {
      await ui.input(k);
      await Bun.sleep(40);
    }
    await anvim!.waitWhere(win, mode);
    await ui.drain();
    await quiet(ui, wait);
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
  await step("back to the prompt", ["<C-w>l"], "input", "n");
  await step("compose window", ["<C-g>"], "anvim_input", "n");
  await step("compose window closes", ["<C-g>"], "input", "n");
  await step("key view", ["?"], "anvim_keys", "n");
  await step("key view closes", ["q"], "input", "n");
  await step("picker", [" ", " "], "snacks_picker_input", "i", 400);
  await step("picker confirms into the code window", ["matchparen", "<CR>"], "code", "n", 400);
  await step("to the prompt again", ["<C-w>l"], "input", "n");
  // <leader>e closes the explorer, and opens it again with the cursor in its
  // list. The mode changes there, in a float, which the global statusline
  // then belongs to.
  await step("explorer closes", [" ", "e"], "input", "n", 400);
  await step("explorer", [" ", "e"], "snacks_picker_list", "n", 400);
  await step("click into the code window", [click("Mouse"), click("Release")], "code", "n");
  await step("to the prompt from the code window", ["<C-w>l"], "input", "n");
  await step("explorer closes again", [" ", "e"], "input", "n", 400);
  await step("explorer again", [" ", "e"], "snacks_picker_list", "n", 400);
  await step("open a file from the explorer", ["G", "<CR>"], "code", "n", 400);
  expect(await ui.exec_lua(`return vim.fn.expand("%:t")`)).toBe("other.lua");
});

// The column where the frame shows `needle` in the code window.
function column(f: Frame, box: Box, needle: string): number | null {
  const row = f.lines.slice(box.row, box.row + box.height).find((l) => cells(l, box.col, box.width).includes(needle));
  return row === undefined ? null : cells(row, box.col, box.width).indexOf(needle);
}

test("the code window's text stays in place when the cursor goes between the prompt and the code window", async () => {
  const short = Array.from({ length: 5 }, (_, i) => `local short${i + 1} = ${i + 1}`).join("\n");
  anvim = await start({ files: { "short.lua": `${short}\n` } });
  const { ui } = anvim;
  for (const [file, needle] of [
    ["matchparen.lua", "local function char_at(text, byte_col)"],
    ["short.lua", "local short3 = 3"],
  ] as const) {
    await anvim.toCode(file, { lnum: 3, topline: 1 });
    const code = await anvim.box("code");
    await ui.drain();
    const mark = ui.mark();
    const at = `<${code.col + 12},${code.row + 2}>`;
    const steps: [string[], string][] = [
      [["<C-w>l"], "input"],
      [["<C-w>h"], "code"],
      [["<C-w>l"], "input"],
      [[`<LeftMouse>${at}`, `<LeftRelease>${at}`], "code"],
      [["<C-w>l"], "input"],
    ];
    for (const [keys, win] of steps) {
      for (const k of keys) await ui.input(k);
      await anvim.waitWhere(win, "n");
      await ui.drain();
      await quiet(ui);
    }
    const cols = ui.frames(mark).flatMap((f) => column(f, code, needle) ?? []);
    expect(cols.length, file).toBeGreaterThan(steps.length);
    expect([...new Set(cols)], file).toEqual([cols[0]!]);
    // Past 'mousetime', so the next file's click is no double click.
    await Bun.sleep(400);
  }
});

test("the review gutter's computed width is the drawn width, also with a wider number, fold or sign column", async () => {
  const lines = (n: number) => Array.from({ length: n }, (_, i) => `local x${i} = ${i}`).join("\n") + "\n";
  anvim = await start({ files: { "five.lua": lines(5), "fifty.lua": lines(50) } });
  const { ui } = anvim;
  const configs = [{}, { numberwidth: 6 }, { foldcolumn: "1" }, { signcolumn: "yes:2" }];
  for (const file of ["five.lua", "fifty.lua"]) {
    await anvim.toCode(file);
    for (const config of configs) {
      const got = await ui.exec_lua<{ computed: number; drawn: number }>(
        `
        local config = ...
        local follow, win = require("anvim.follow"), require("anvim.layout").wins.code
        local review = follow.review_options()
        review.signcolumn = config.signcolumn or "yes"
        vim.wo[win].numberwidth = config.numberwidth or 4
        vim.wo[win].foldcolumn = config.foldcolumn or "0"
        follow.apply(win)
        vim.cmd.redraw()
        return { computed = follow.review_width(win), drawn = vim.fn.getwininfo(win)[1].textoff }
      `,
        config,
      );
      expect(got.computed, `${file} ${JSON.stringify(config)}`).toBe(got.drawn);
    }
  }
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
