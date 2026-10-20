import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, cursorIn, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const view = () =>
  anvim!.ui.exec_lua<{ top: number; bottom: number; last: number }>(`
    local win = require("anvim.layout").wins.transcript
    return { top = vim.fn.line("w0", win), bottom = vim.fn.line("w$", win), last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) }
  `);

const rows = (box: Box) =>
  anvim!.ui
    .lines()
    .slice(box.row, box.row + box.height)
    .map((l) => cells(l, box.col, box.width));

test("a click in the transcript lands in the prompt, and the wheel scrolls it without moving the cursor", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.notices(60, "transcript line");
  const transcript = await anvim.box("transcript");
  const input = await anvim.box("input");
  await ui.waitFor("transcript line 60");

  await anvim.toCode();
  let mark = ui.mark();
  await ui.inputMouse("left", "press", transcript.row + 5, transcript.col + 5);
  await ui.inputMouse("left", "release", transcript.row + 5, transcript.col + 5);
  await anvim.waitWhere("input", "n");
  await ui.waitFor(() => inBox(ui.cursor, input) && ui.mode === "normal");
  expect(cursorIn(ui.frames(mark), transcript)).toEqual([]);

  await anvim.toCode();
  const code = await anvim.box("code");
  const before = await view();
  const shown = rows(transcript);
  mark = ui.mark();
  await ui.inputMouse("wheel", "up", transcript.row + 5, transcript.col + 5);
  await ui.waitFor(async () => (await view()).top < before.top);
  await ui.waitFor(() => rows(transcript).join("\n") !== shown.join("\n"));
  expect(await anvim.where()).toEqual({ win: "code", mode: "n" });
  expect(ui.frames(mark).flatMap((f) => (inBox(f.cursor, code) ? [] : [f.cursor]))).toEqual([]);
});

test("a mouse drag in the transcript selects the dragged lines, at its top and near its bottom", async () => {
  anvim = await start();
  const { ui } = anvim;
  expect(await ui.exec_lua(`return Snacks.scroll.enabled`)).toBe(true);
  // One notice, so that every row has text to select.
  await ui.exec_lua(`
    local lines = {}
    for i = 1, 60 do
      lines[i] = "row text " .. i
    end
    require("anvim.transcript").notice("warn", table.concat(lines, "\\n"))
  `);
  await ui.waitFor("row text 60");
  const transcript = await anvim.box("transcript");

  // Presses at row, drags down four rows at a hand's pace, and releases.
  const drag = async (row: number) => {
    const { top } = await view();
    const col = transcript.col + 4;
    await ui.inputMouse("left", "press", transcript.row + row, col);
    for (let i = 1; i <= 4; i++) {
      await Bun.sleep(60);
      await ui.inputMouse("left", "drag", transcript.row + row + i, col + 4);
    }
    await Bun.sleep(60);
    await ui.inputMouse("left", "release", transcript.row + row + 4, col + 4);
    await anvim!.waitWhere("transcript", "v");
    const got = await ui.exec_lua(`return { vim.fn.getpos("v")[2], vim.fn.line(".") }`);
    expect(got, `drag from row ${row}`).toEqual([top + row, top + row + 4]);
    // The selection shows on exactly those rows.
    const selected = (r: number) => {
      const cell = ui.grid[r]?.[col + 1];
      return cell !== undefined && (ui.attrs.get(cell.hl)?.names ?? "").includes("Visual");
    };
    await ui.waitFor(() => [0, 1, 2, 3, 4].every((i) => selected(transcript.row + row + i)));
    expect(selected(transcript.row + row - 1) || selected(transcript.row + row + 5), `drag from row ${row}`).toBe(false);
    await ui.input("<Esc>q");
    await anvim!.waitWhere("input", "n");
  };

  await drag(2);
  // Scroll up, so the end of the transcript is out of view, and let the
  // scroll animation finish.
  await ui.exec_lua(`require("anvim.windows").scroll("<C-u>")`);
  let last = (await view()).top;
  await ui.waitFor(async () => {
    await Bun.sleep(100);
    const top = (await view()).top;
    const still = top === last;
    last = top;
    return still;
  });
  await drag(transcript.height - 6);
});
