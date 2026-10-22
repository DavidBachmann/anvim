// The global statusline is anvim's own. Its mode block reads Vim's mode, or
// FOLLOW in follow mode, in the mode's color, and Neovim draws each change
// without a request from outside.
import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const row = () => anvim!.ui.exec_lua<number>(`return vim.o.lines - vim.o.cmdheight - 1`);
const text = (f: Frame, r: number) => (f.lines[r] ?? "").trim().split(" ")[0];

// The block's text and the colors of its first letter, as the grid shows them.
async function block() {
  const { ui } = anvim!;
  const r = await row();
  const rgb = ui.attrs.get(ui.grid[r]![1]!.hl)?.rgb ?? {};
  return { text: ui.lines()[r]!.trim().split(" ")[0], bg: rgb.background, bold: !!rgb.bold };
}

const colors = (group: string) =>
  anvim!.ui.exec_lua<{ bg: number; bold: boolean }>(
    `
    local hl = vim.api.nvim_get_hl(0, { name = ..., link = false })
    return { bg = hl.bg, bold = hl.bold == true }
  `,
    group,
  );

test("the mode block shows each of Vim's modes in its color, and FOLLOW in Claude's", async () => {
  anvim = await start();
  const { ui } = anvim;
  const r = await row();
  // Only the grid is read while waiting, so Neovim draws each mode on its own.
  const shows = async (want: string, group: string) => {
    await ui.waitFor(() => ui.lines()[r]!.trim().startsWith(want + " "), 2000);
    const got = await block();
    const hl = await colors(group);
    expect({ text: got.text, bg: got.bg, bold: got.bold }).toEqual({ text: want, bg: hl.bg, bold: hl.bold });
  };
  await shows("FOLLOW", "AnvimStatusFollow");
  // From the first frame that shows anything, the statusline is anvim's.
  const drawn = ui.frames(0).filter((f) => f.lines.some((l) => l.trim() !== ""));
  expect(drawn.length).toBeGreaterThan(0);
  expect(drawn.map((f) => text(f, r)).filter((t) => t !== "NORMAL" && t !== "FOLLOW")).toEqual([]);
  expect((await colors("AnvimStatusFollow")).bg).toBe(
    await ui.exec_lua<number>(`return vim.api.nvim_get_hl(0, { name = "AnvimClaude", link = false }).fg`),
  );
  await anvim.insert();
  await shows("FOLLOW", "AnvimStatusFollow");
  await ui.input("<Esc>");
  await anvim.toCode();
  await shows("NORMAL", "AnvimStatusNormal");
  // After a cursor move and a pause, <C-v> alone did not draw the statusline.
  await ui.input("j");
  await Bun.sleep(400);
  await ui.drain();
  await ui.input("<C-v>");
  await shows("V-BLOCK", "AnvimStatusVisual");
  await ui.input("<Esc>");
  await shows("NORMAL", "AnvimStatusNormal");
  await ui.input("v");
  await shows("VISUAL", "AnvimStatusVisual");
  await ui.input("<Esc>");
  await shows("NORMAL", "AnvimStatusNormal");
  await ui.input("V");
  await shows("V-LINE", "AnvimStatusVisual");
  await ui.input("<Esc>");
  await shows("NORMAL", "AnvimStatusNormal");
  await ui.input(":");
  await shows("COMMAND", "AnvimStatusCommand");
  await ui.input("<Esc>");
  await shows("NORMAL", "AnvimStatusNormal");
  const kinds = await ui.exec_lua<number[]>(`
    local out = {}
    for _, kind in ipairs({ "Normal", "Insert", "Visual", "Command" }) do
      out[#out + 1] = vim.api.nvim_get_hl(0, { name = "AnvimStatus" .. kind, link = false }).bg
    end
    return out
  `);
  expect(new Set(kinds).size).toBe(4);
});

test("no frame shows the block of the window before, through a picker and the explorer", async () => {
  anvim = await start();
  const { ui } = anvim;
  const r = await row();
  const code = await anvim.box("code");
  const input = await anvim.box("input");
  // A picker over the code window keeps the prompt's follow mode while it is
  // open. Once it shows no more, the code window has review mode.
  const open = ui.mark();
  await ui.input(" ");
  await ui.input(" ");
  await anvim.waitWhere("snacks_picker_input", "i");
  await Bun.sleep(300);
  await ui.input("matchparen");
  await Bun.sleep(300);
  await ui.drain();
  const confirm = ui.mark();
  await ui.input("<CR>");
  await anvim.waitWhere("code", "n");
  await Bun.sleep(300);
  await ui.drain();
  const back = ui.mark();
  await ui.input("<C-w>l");
  await anvim.waitWhere("input", "n");
  // <leader>e closes the explorer, and opens it again with the cursor in its list.
  await ui.input(" e");
  await ui.waitFor(() => ui.exec_lua<boolean>(`return require("anvim.tree").explorer() == nil`));
  await ui.input(" e");
  await anvim.waitWhere("snacks_picker_list", "n");
  await Bun.sleep(300);
  await ui.drain();
  const tree = await anvim.box("tree");
  const picker = (f: Frame) => f.lines.some((l) => l.includes("matchparen") && l.includes("1/1"));
  const wrong = (from: number, to: number, want: (f: Frame) => string | null) =>
    ui.frames(from).slice(0, to - from).flatMap((f, i) => {
      const w = want(f);
      return w && text(f, r) !== w ? [`#${from + i}: ${text(f, r)} for ${w} at ${JSON.stringify(f.cursor)}`] : [];
    });
  expect(wrong(open, confirm, () => "FOLLOW")).toEqual([]);
  expect(ui.frames(open).slice(0, confirm - open).some(picker)).toBe(true);
  const closed = wrong(confirm, back, (f) => (inBox(f.cursor, code) && !picker(f) ? "NORMAL" : null));
  expect(closed).toEqual([]);
  expect(ui.frames(confirm).slice(0, back - confirm).some((f) => inBox(f.cursor, code) && !picker(f))).toBe(true);
  const after = wrong(back, ui.mark(), (f) =>
    inBox(f.cursor, tree) ? "NORMAL" : inBox(f.cursor, input) ? "FOLLOW" : null,
  );
  expect(after).toEqual([]);
  expect(ui.frames(back).some((f) => inBox(f.cursor, tree))).toBe(true);
  expect((await block()).text).toBe("NORMAL");
});

test("a colorscheme whose StatusLine is bold and reversed reverses no cell, and bolds only the mode", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode();
  await ui.exec_lua(`
    vim.cmd.colorscheme("retrobox")
    vim.b.gitsigns_status_dict = { added = 2, changed = 1, removed = 1 }
    local ns = vim.api.nvim_create_namespace("statusline_test")
    vim.diagnostic.set(ns, 0, { { lnum = 0, col = 0, message = "e", severity = 1 } })
  `);
  const status = await ui.exec_lua<{ reverse: boolean; bold: boolean }>(`
    local hl = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
    return { reverse = hl.reverse == true, bold = hl.bold == true }
  `);
  expect(status).toEqual({ reverse: true, bold: true });
  const r = await row();
  await ui.waitFor(() => ui.lines()[r]!.includes("Top"), 2000);
  await ui.drain();
  const line = ui.lines()[r]!;
  const block = line.indexOf("NORMAL") + "NORMAL".length + 1;
  const cells = ui.grid[r]!.map((cell, col) => ({ col, text: cell.text, rgb: ui.attrs.get(cell.hl)?.rgb ?? {} }));
  expect(cells.filter((c) => c.rgb.reverse).map((c) => c.col)).toEqual([]);
  expect(cells.filter((c) => c.rgb.bold && c.col > block).map((c) => c.col)).toEqual([]);
});
