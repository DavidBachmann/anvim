// The key view: it fits a 200x48 screen, and closing it gives the cursor back
// to the prompt, in its mode, without a frame in the transcript.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, cursorIn, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

type View = { lines: number; height: number; top: number; bottom: number };

const VIEW = `
  local win = require("anvim.keyview").win()
  if not win then
    return vim.NIL
  end
  return {
    lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)),
    height = vim.api.nvim_win_get_height(win),
    top = vim.fn.line("w0", win),
    bottom = vim.fn.line("w$", win),
  }
`;

// The name of each place, and the text of each of its rows.
const PLACES = `
  local ret = {}
  for _, place in ipairs(require("anvim.keys").places) do
    if place.ctx ~= "view" then
      ret[#ret + 1] = place.name
      for _, key in ipairs(place.keys) do
        ret[#ret + 1] = key.row or key[2]
      end
    end
  end
  return ret
`;

const view = () => anvim!.ui.exec_lua<View | null>(VIEW);

async function open(keys: string) {
  await anvim!.ui.input(keys);
  await anvim!.waitWhere("anvim_keys", "n");
}

test("at 200x48 the key view shows every place and every key, without scrolling", async () => {
  anvim = await start({ cols: 200, rows: 48 });
  const { ui } = anvim;
  await open("?");
  const texts = await ui.exec_lua<string[]>(PLACES);
  await ui.waitFor(() => texts.every((text) => ui.screen().includes(text)));
  const v = await view();
  expect(v).toEqual({ lines: v!.lines, height: v!.lines, top: 1, bottom: v!.lines });
  expect(ui.screen()).not.toContain("j k scroll");
});

test("closing the key view puts the cursor back in the prompt, in its mode, with no frame in the transcript", async () => {
  anvim = await start();
  const { ui } = anvim;
  const transcript = await anvim.box("transcript");
  for (const [mode, close] of [
    ["i", "q"],
    ["n", "<Esc>"],
  ] as const) {
    if (mode === "i") await anvim.insert();
    await open("?");
    const mark = ui.mark();
    await ui.input(close);
    await anvim.waitWhere("input", mode);
    await ui.drain();
    expect(await view()).toBeNull();
    expect(cursorIn(ui.frames(mark), transcript)).toEqual([]);
    if (mode === "i") {
      await ui.input("<Esc>");
      await anvim.waitWhere("input", "n");
    }
  }
});
