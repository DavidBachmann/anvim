import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, type Box, cells, cursorIn, inBox, settle, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// Every row of the box has a vertical separator in each of the columns.
const walls = (lines: string[], box: Box, cols: number[]) =>
  lines.slice(box.row, box.row + box.height).every((line) => cols.every((c) => [...line][c] === "│"));

// A second window in the box: a row of horizontal rule, or a column of
// vertical bars, inside it.
function splitIn(f: Frame, box: Box): string | null {
  for (let r = box.row + 1; r < box.row + box.height - 1; r++) {
    const seg = cells(f.lines[r] ?? "", box.col + 2, box.width - 4);
    if (/^─+$/.test(seg)) return `rule in row ${r}`;
  }
  for (let c = box.col + 2; c < box.col + box.width - 2; c++) {
    let n = 0;
    for (let r = box.row; r < box.row + box.height; r++) if ([...(f.lines[r] ?? "")][c] === "│") n++;
    if (n > box.height - 3) return `bars in column ${c}`;
  }
  return null;
}

const codeWin = () => anvim!.ui.exec_lua<number>(`return require("anvim.layout").wins.code`);

test("closing the code window with the explorer open reopens it, with the widths and the cursor", async () => {
  anvim = await start();
  const { ui } = anvim;
  for (const keys of [":close<CR>", "<C-w>c"]) {
    await anvim.toCode();
    await ui.waitFor("local api = vim.api");
    const tree = await anvim.box("tree");
    const code = await anvim.box("code");
    const transcript = await anvim.box("transcript");
    const cols = [tree.width, code.col + code.width];
    expect(walls(ui.lines(), code, cols)).toBe(true);
    const win = await codeWin();
    const mark = ui.mark();
    await ui.input(keys);
    await ui.waitFor(async () => (await codeWin()) !== win);
    await anvim.waitWhere("code", "n");
    expect(await anvim.box("tree")).toEqual(tree);
    expect(await anvim.box("code")).toEqual(code);
    expect(await anvim.box("transcript")).toEqual(transcript);
    await ui.waitFor(() => walls(ui.lines(), code, cols) && inBox(ui.cursor, code));
    expect(cursorIn(ui.frames(mark), tree)).toEqual([]);
  }
});

// Neovim gives the closed window's columns to the tree, and the explorer
// flushes a redraw from WinResized. anvim must reopen the code window first.
test("no frame shows the tree over the closed code window's columns", async () => {
  anvim = await start();
  const { ui } = anvim;
  for (const keys of [":close<CR>", "<C-w>c"]) {
    await anvim.toCode();
    await ui.waitFor("local api = vim.api");
    const tree = await anvim.box("tree");
    const code = await anvim.box("code");
    const win = await codeWin();
    const mark = ui.mark();
    await ui.input(keys);
    await ui.waitFor(async () => (await codeWin()) !== win);
    await anvim.waitWhere("code", "n");
    const torn = ui.frames(mark).filter((f) => !walls(f.lines, code, [tree.width]));
    expect(torn.length, keys).toBe(0);
  }
});

// A split copies the options of the window that it splits, and here that is
// the prompt.
test("<C-w>o in the prompt reopens a code window without the Claude column's background", async () => {
  anvim = await start();
  const { ui } = anvim;
  const win = await codeWin();
  await ui.input("<C-w>o");
  await ui.waitFor(async () => (await codeWin()) !== win);
  const winhl = await ui.exec_lua<string>(`return vim.wo[require("anvim.layout").wins.code].winhighlight`);
  expect(winhl).not.toContain("AnvimNormal");
});

test("the activity line's rule has AnvimRule's color on the Claude column's background", async () => {
  anvim = await start();
  const { ui } = anvim;
  const want = await ui.exec_lua<{ fg: number; bg: number }>(`
    return {
      fg = vim.api.nvim_get_hl(0, { name = "AnvimRule", link = false }).fg,
      bg = vim.api.nvim_get_hl(0, { name = "AnvimNormal", link = false }).bg,
    }
  `);
  const input = await anvim.box("input");
  const transcript = await anvim.box("transcript");
  await ui.waitFor(() => cells(ui.lines()[input.row]!, input.col, input.width).includes("────"));
  const colors = (row: number, col: number, width: number, text: string) =>
    ui.grid[row]!.slice(col, col + width)
      .filter((cell) => cell.text === text)
      .map((cell) => {
        const rgb = ui.attrs.get(cell.hl)?.rgb ?? {};
        return { fg: rgb.foreground, bg: rgb.background ?? ui.defaults.bg };
      });
  const rule = colors(input.row, input.col, input.width, "─");
  expect(rule.length).toBeGreaterThan(0);
  expect(rule.every((c) => c.fg === want.fg && c.bg === want.bg)).toBe(true);
  // The transcript's last row is blank before a turn.
  const blank = colors(transcript.row + transcript.height - 1, transcript.col, transcript.width, " ");
  expect(blank.length).toBe(transcript.width);
  expect(blank.every((c) => c.bg === want.bg)).toBe(true);
});

test("splits in the code window fold back before a frame shows them, at the same view", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    _G.anvim_wins_made = 0
    vim.api.nvim_create_autocmd("WinNew", { callback = function() _G.anvim_wins_made = _G.anvim_wins_made + 1 end })
  `);
  const folded = `
    local layout = require("anvim.layout")
    local code, n = layout.wins.code, 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" and layout.is_code(vim.api.nvim_win_get_buf(win)) then
        n = n + 1
      end
    end
    return _G.anvim_wins_made > ... and n == 1 and vim.api.nvim_get_current_win() == code
      and { line = vim.api.nvim_win_get_cursor(code)[1], top = vim.fn.line("w0", code) }
  `;
  for (const keys of ["<C-w>s", "<C-w>v", ":split<CR>", ":vsplit<CR>"]) {
    await anvim.toCode("matchparen.lua", { lnum: 20, topline: 10 });
    const box = await anvim.box("code");
    const made = await ui.exec_lua<number>(`return _G.anvim_wins_made`);
    const mark = ui.mark();
    await ui.input(keys);
    const view = await ui.waitFor(() => ui.exec_lua(folded, made));
    expect(view, keys).toEqual({ line: 20, top: 10 });
    // The number column shows 20 on the cursor line, and the relative 10 on the top row.
    await ui.waitFor(() => {
      const cursorRow = cells(ui.lines()[ui.cursor.row]!, box.col, 8);
      const topRow = cells(ui.lines()[box.row]!, box.col, 8);
      return ui.cursor.row - box.row === 10 && /^\s*20\s/.test(cursorRow) && /^\s*10\s/.test(topRow);
    });
    const splits = ui.frames(mark).flatMap((f) => splitIn(f, box) ?? []);
    expect(splits, keys).toEqual([]);
  }
});

test("<C-l> and <C-w>l from the code window reach the prompt in normal mode, and no frame shows the cursor in the transcript", async () => {
  anvim = await start();
  const { ui } = anvim;
  for (const key of ["<C-l>", "<C-w>l"]) {
    // H puts the cursor next to the transcript, G next to the prompt.
    for (const motion of ["H", "M", "L", "gg", "G"]) {
      await anvim.toCode();
      const transcript = await anvim.box("transcript");
      const input = await anvim.box("input");
      const mark = ui.mark();
      await ui.input(motion + key);
      await anvim.waitWhere("input", "n");
      await ui.waitFor(() => inBox(ui.cursor, input) && ui.mode === "normal");
      expect(cursorIn(ui.frames(mark), transcript), motion + key).toEqual([]);
    }
  }
});

test("anvim starts in the prompt in normal mode, the first keys can move, and only i types", async () => {
  anvim = await start();
  const { ui } = anvim;
  // The explorer and the sidecar finish starting after this. They must not
  // start insert mode.
  await Bun.sleep(1000);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
  expect(ui.frames().filter((f) => f.mode === "insert").length).toBe(0);
  await ui.input("<C-h>");
  await anvim.waitWhere("code", "n");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.input("<C-h>i");
  await anvim.waitWhere("input", "i");
});

test("a terminal resize with the prompt focused keeps the layout", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.insert();
  const tree = await anvim.box("tree");
  for (const [cols, rows] of [
    [160, 40],
    [120, 30],
    [90, 24],
    [200, 48],
  ] as const) {
    const size = `${cols}x${rows}`;
    await ui.resize(cols, rows);
    await ui.waitFor(() => ui.grid.length === rows && ui.grid[0]!.length === cols);
    // The Claude column keeps its share, and the code window takes the rest.
    const claude = Math.floor(cols * 0.36);
    const want = {
      prompts: 1,
      cmdheight: 1,
      code: { row: 0, col: tree.width + 1, width: cols - tree.width - claude - 2 },
      transcript: { row: 0, col: cols - claude, width: claude },
      // The statusline and the command line take the last two rows.
      input: { col: cols - claude, width: claude, bottom: rows - 2 },
    };
    const got = await settle(
      () =>
        ui.exec_lua(`
          local wins = require("anvim.layout").wins
          local function box(win)
            local pos = vim.fn.win_screenpos(win)
            return { row = pos[1] - 1, col = pos[2] - 1, width = vim.api.nvim_win_get_width(win) }
          end
          local input = box(wins.input)
          input.bottom, input.row = input.row + vim.api.nvim_win_get_height(wins.input), nil
          return {
            prompts = #vim.fn.win_findbuf(require("anvim.input").buf()),
            cmdheight = vim.o.cmdheight,
            code = box(wins.code),
            transcript = box(wins.transcript),
            input = input,
          }
        `),
      (got) => Bun.deepEquals(got, want),
    );
    expect(got, size).toEqual(want);
    await anvim.waitWhere("input", "i");
    // One prompt on the screen, under the activity line, with the cursor.
    const input = await anvim.box("input");
    const prompts = ui.lines().flatMap((l, r) => (l.includes("❯") ? [r] : []));
    expect(prompts, size).toEqual([input.row + 1]);
    await ui.waitFor(() => inBox(ui.cursor, input) && ui.mode === "insert");
  }
});
