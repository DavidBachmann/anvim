// Follow mode hides the code window's line numbers, so a Write preview that
// grows past 9 lines never pushes its text to the right. Review mode shows
// them, and the switch shows in the frame of the cursor's move.
import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, type Box, cells, quiet, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
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
