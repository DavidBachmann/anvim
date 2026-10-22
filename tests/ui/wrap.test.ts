// Long lines wrap in the code window, and <leader>uw turns that off for code.
// The choice lasts to the next start. Markdown and text always wrap.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const files = {
  "long.lua": `local long = "${"word ".repeat(60)}"\nreturn long\n`,
  "notes.md": `${"Some prose that goes on. ".repeat(12)}\n\nThe end.\n`,
};

// The first rows of the code window's text.
async function rows(n = 2) {
  const code = await anvim!.box("code");
  return anvim!.ui.lines().slice(code.row, code.row + n).map((line) => cells(line, code.col, code.width));
}

const saved = () =>
  anvim!.ui.exec_lua<boolean | null>(`
    local f = io.open(require("anvim.prefs").path)
    if not f then
      return vim.NIL
    end
    local data = vim.json.decode(f:read("*a"))
    f:close()
    return data.code_wrap
  `);

test("a long line wraps with a mark on the next row, and <leader>uw from the prompt cuts it and remembers that", async () => {
  anvim = await start({ files });
  const { ui } = anvim;
  await anvim.toCode("long.lua");
  await ui.waitFor(async () => (await rows())[1]!.includes("↪ word"));
  expect((await rows())[0]).toContain('local long = "word');

  await ui.exec_lua(`require("anvim.layout").focus_input({ insert = false })`);
  await anvim.waitWhere("input", "n");
  await ui.input("<Space>uw");
  await ui.waitFor(async () => (await rows())[1]!.includes("return long"));
  expect((await rows())[0]).not.toContain("↪");
  expect(await saved()).toBe(false);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
});

test("a start after wrap was turned off cuts code, and markdown still wraps without the mark", async () => {
  anvim = await start({ files, prefs: { code_wrap: false } });
  const { ui } = anvim;
  await anvim.toCode("long.lua");
  await ui.waitFor(async () => (await rows())[1]!.includes("return long"));

  await anvim.toCode("notes.md");
  await ui.waitFor(async () => (await rows())[1]!.includes("prose that goes on"));
  expect((await rows())[1]).not.toContain("↪");
});
