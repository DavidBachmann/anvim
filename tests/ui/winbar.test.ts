// The code window's winbar names the file that it shows. While the cursor is
// in the prompt, the statusline names the prompt, so the winbar is where the
// user sees which file Claude is in.
import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { type Anvim, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const MOD = "lua/deep/mod.lua";

// The winbar's row: the row above the code window's text.
async function winbar() {
  const { ui } = anvim!;
  const code = await anvim!.box("code");
  const row = code.row - 1;
  const text = cells(ui.lines()[row]!, code.col, code.width);
  const runs = ui.grid[row]!.slice(code.col, code.col + code.width).map((c) => ui.attrs.get(c.hl));
  return { text: text.trim(), row, code, runs };
}

// The group names and the background of the cells under each match of text.
async function look(text: string) {
  const { ui } = anvim!;
  const bar = await winbar();
  const at = [...cells(ui.lines()[bar.row]!, bar.code.col, bar.code.width)].join("").indexOf(text);
  const attrs = bar.runs.slice(at, at + text.length);
  return { fg: new Set(attrs.map((a) => a?.rgb.foreground)), bg: new Set(attrs.map((a) => a?.rgb.background)) };
}

const fg = (group: string) =>
  anvim!.ui.exec_lua<number>(`return vim.api.nvim_get_hl(0, { name = ..., link = false }).fg`, group);

test("the winbar names the file relative to the cwd, and absolute outside it, on the code's background", async () => {
  anvim = await start({ files: { [MOD]: "return 1\n" } });
  const { ui } = anvim;
  await anvim.toCode(MOD);
  await ui.waitFor(async () => (await winbar()).text === MOD);
  const mod = await look(MOD);
  expect(mod.fg).toEqual(new Set([await fg("Comment")]));
  // No background of its own, as the code under it. WinBar has the statusline's.
  expect(mod.bg).toEqual(new Set([undefined]));

  const outside = join(dirname(anvim.dir), "outside.lua");
  writeFileSync(outside, "return 2\n");
  await anvim.toCode(join("..", "outside.lua"));
  await ui.waitFor(async () => (await winbar()).text === outside);
});

test("the winbar stays with the code window: a split, a float and the compose window have none", async () => {
  anvim = await start({ files: { [MOD]: "return 1\n" } });
  const { ui } = anvim;
  await anvim.toCode(MOD);
  await ui.waitFor(async () => (await winbar()).text === MOD);
  const splits = () =>
    ui.exec_lua<number>(`return #vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative == ""
    end, vim.api.nvim_tabpage_list_wins(0))`);
  const before = await splits();
  const got = await ui.exec_lua<Record<string, string>>(`
    local api = vim.api
    local code = require("anvim.layout").wins.code
    local function winbar(win)
      return vim.wo[win].winbar
    end
    local ret = {}
    -- A float and a split that show the code window's buffer copy its winbar.
    local float = api.nvim_open_win(0, false, { relative = "win", win = code, row = 2, col = 2, width = 20, height = 3 })
    ret.float = winbar(float)
    api.nvim_win_close(float, true)
    local split = api.nvim_open_win(0, false, { split = "below", win = code })
    ret.split = winbar(split)
    local _, hover = vim.lsp.util.open_floating_preview({ "hover text" }, "markdown")
    ret.hover = winbar(hover)
    api.nvim_win_close(hover, true)
    ret.code = winbar(code)
    return ret
  `);
  expect(got).toEqual({
    float: "",
    split: "",
    hover: "",
    code: "%!v:lua.require'anvim.layout'.winbar_text()",
  });
  // The split folds back into the code window, which keeps its winbar.
  await ui.waitFor(async () => (await splits()) === before);
  await ui.waitFor(async () => (await winbar()).text === MOD);

  await ui.input("<C-w>l");
  await anvim.waitWhere("input", "n");
  await ui.input("<C-g>");
  await anvim.waitWhere("anvim_input", "n");
  const compose = await ui.exec_lua<string>(`return vim.wo.winbar`);
  expect(compose).toBe("");
  // One row names the file: the code window's winbar.
  expect(ui.lines().filter((l) => l.includes(MOD)).length).toBe(1);
});

test("a picker's preview of a buffer that the code window showed last has no winbar", async () => {
  anvim = await start({ files: { [MOD]: "return 1\n" } });
  const { ui } = anvim;
  await anvim.toCode(MOD);
  await anvim.toCode();
  // The preview shows the loaded buffer, which brings the options it had in the code window.
  await ui.exec_lua(`Snacks.picker.buffers()`);
  const others = () =>
    ui.exec_lua<string[]>(`
      local layout, ret = require("anvim.layout"), {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= layout.wins.code and vim.wo[win].winbar == layout.code_options.winbar then
          ret[#ret + 1] = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        end
      end
      return ret
    `);
  const previewing = () =>
    ui.exec_lua<boolean>(`
      local picker = Snacks.picker.get({ source = "buffers" })[1]
      local win = picker and picker.preview.win.win
      return win ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("mod.lua", 1, true) ~= nil
    `);
  await ui.waitFor(previewing);
  await ui.drain();
  expect(await others()).toEqual([]);
  expect(ui.lines().filter((l) => l.includes(MOD)).length).toBeLessThanOrEqual(1);
});

const field = (key: string, phase: string, x?: string) =>
  anvim!.ui.exec_lua(
    `
    local key, phase, x = ...
    require("anvim.sidecar").dispatch({ type = "tool_field", id = "w1", name = "Write", key = key, phase = phase,
      text = phase == "delta" and x or nil, value = phase == "end" and x or nil })
  `,
    key,
    phase,
    x ?? null,
  );

test("a Write preview's winbar and statusline name the real file, and the winbar says (writing)", async () => {
  anvim = await start();
  const { ui } = anvim;
  const path = join(anvim.dir, "made.lua");
  await ui.exec_lua(`
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "turn_start" })
    sidecar.dispatch({ type = "tool_start", id = "w1", name = "Write" })
  `);
  await field("file_path", "end", path);
  await field("content", "start");
  await field("content", "delta", "local made = 1\n");
  await ui.waitFor("local made = 1");
  await ui.waitFor(async () => (await winbar()).text === "made.lua (writing)");
  expect(await look("(writing)")).toEqual({ fg: new Set([await fg("AnvimClaude")]), bg: new Set([undefined]) });
  expect(await look("made.lua")).toEqual({ fg: new Set([await fg("Comment")]), bg: new Set([undefined]) });

  // In the code window, the statusline names the file too. A separator
  // comes before (writing).
  await ui.input("<C-w>h");
  await anvim.waitWhere("code", "n");
  const status = async () => ui.lines()[(await ui.exec_lua<number>(`return vim.o.lines - vim.o.cmdheight - 1`))]!;
  await ui.waitFor(async () => / made\.lua .{0,3}\(writing\)/.test(await status()));
  expect(await status()).not.toContain("write/");
  expect(ui.screen()).not.toContain("anvim://");
});
