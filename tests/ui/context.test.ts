// Pointing with real keys: a pinned selection, its footer chip, and follow
// mode waiting while Claude reads another file.
import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Anvim, type Box, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// The code window's lines, from 1, that show the selection highlight.
function highlighted(box: Box, first: number, last: number): number[] {
  const { grid, attrs } = anvim!.ui;
  const out: number[] = [];
  for (let lnum = first; lnum <= last; lnum++) {
    const row = grid[box.row + lnum - 1]!.slice(box.col, box.col + box.width);
    if (row.some((cell) => attrs.get(cell.hl)?.names.split("+").includes("Visual"))) out.push(lnum);
  }
  return out;
}

test("V2j and <C-l> pin the lines with a footer chip, and follow mode waits until <C-x> unpins", async () => {
  anvim = await start();
  const { ui } = anvim;
  const other = join(anvim.dir, "other.lua");
  writeFileSync(other, "local other = 1\nreturn other\n");
  await anvim.toCode("matchparen.lua", { lnum: 10, topline: 1 });
  await ui.waitFor("---@param byte_col integer");
  await anvim.type("V2j");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.waitFor("⧉ 3 lines selected");
  const code = await anvim.box("code");
  expect(cells(ui.lines()[code.row + 9]!, code.col, code.width)).toContain("---@param byte_col integer");
  await ui.waitFor(() => highlighted(code, 9, 13).length === 3);
  expect(highlighted(code, 9, 13)).toEqual([10, 11, 12]);

  const mark = ui.mark();
  await ui.exec_lua(
    `require("anvim.sidecar").dispatch({ type = "tool_use", id = "ui1", name = "Read", input = { file_path = ... } })`,
    other,
  );
  await ui.waitFor("⏸ pinned · Claude at other.lua:1 +1");
  await ui.drain();
  expect(ui.frames(mark).some((f) => f.lines.some((line) => line.includes("local other = 1")))).toBe(false);
  expect(highlighted(code, 9, 13)).toEqual([10, 11, 12]);
  expect(ui.screen()).toContain("⧉ 3 lines selected");

  await ui.input("<C-x>");
  await ui.waitFor("local other = 1");
  await ui.waitFor("⧉ In other.lua");
  await ui.waitFor("◉ following");
  expect(ui.screen()).not.toContain("⏸ pinned");
});

test("a narrow statusline keeps the pause sign and Claude's place in view", async () => {
  anvim = await start({ cols: 70 });
  const { ui } = anvim;
  writeFileSync(join(anvim.dir, "other.lua"), "local other = 1\nreturn other\n");
  await anvim.toCode("matchparen.lua", { lnum: 10, topline: 1 });
  await anvim.type("Vj");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.exec_lua(
    `require("anvim.sidecar").dispatch({ type = "tool_use", id = "un1", name = "Read", input = { file_path = ... } })`,
    join(anvim.dir, "other.lua"),
  );
  await ui.waitFor("⏸ other.lua:1 +1");
  // The global statusline is the last row.
  const status = ui.lines().at(-1)!;
  expect(status).toContain("⏸ other.lua:1 +1");
  expect(status).not.toContain("<");
});

test("a Write that starts while a selection is pinned streams in view once <C-x> unpins", async () => {
  anvim = await start();
  const { ui } = anvim;
  const path = join(anvim.dir, "made_new.lua");
  // A streamed field of the Write tool call, the way the sidecar sends it.
  const field = (key: string, phase: string, x = "") =>
    ui.exec_lua(
      `
      local key, phase, x = ...
      require("anvim.sidecar").dispatch({
        type = "tool_field", id = "uw1", name = "Write", key = key, phase = phase,
        text = phase == "delta" and x or nil, value = phase == "end" and x or nil,
      })
    `,
      key,
      phase,
      x,
    );
  await anvim.toCode("matchparen.lua", { lnum: 10, topline: 1 });
  await ui.waitFor("---@param byte_col integer");
  await anvim.type("V2j");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.waitFor("⧉ 3 lines selected");
  const code = await anvim.box("code");
  const inCode = (text: string) =>
    ui.lines().slice(code.row, code.row + code.height).some((line) => cells(line, code.col, code.width).includes(text));

  await ui.exec_lua(`require("anvim.sidecar").dispatch({ type = "tool_start", id = "uw1", name = "Write" })`);
  await field("file_path", "end", path);
  await field("content", "start");
  await field("content", "delta", "local made = 1\n");
  await ui.waitFor("⏸ pinned · Claude at made_new.lua:1 +1");
  expect(inCode("---@param byte_col integer")).toBe(true);
  expect(inCode("local made = 1")).toBe(false);

  await ui.input("<C-x>");
  await ui.waitFor(() => inCode("local made = 1"));
  await field("content", "delta", "local more = 2\nreturn made + more\n");
  await field("content", "end", "local made = 1\nlocal more = 2\nreturn made + more\n");
  await ui.exec_lua(`require("anvim.sidecar").dispatch({ type = "tool_input_end", id = "uw1" })`);
  await ui.waitFor(() => inCode("return made + more"));
  expect(ui.screen()).toContain("◉ following");
});
