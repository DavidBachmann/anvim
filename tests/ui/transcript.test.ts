// The transcript as it draws: Claude Code's todo list in place, Claude's
// markdown, and a subagent's tool calls under its line.
import { afterEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Anvim, type Box, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// A haiku session with three tasks (TaskCreate and TaskUpdate), an Explore
// subagent, show_user and a markdown reply, then a /compact.
async function tasksSession() {
  anvim = await start({ recording: "tasks-session.jsonl", env: { ANVIM_REPLAY_SPEED: "8" } });
  writeFileSync(join(anvim.dir, "notes.lua"), "local M = {}\n\nreturn M\n");
  writeFileSync(join(anvim.dir, "util.lua"), 'local M = {}\n\nfunction M.trim(s)\n  return (s:gsub("^%s+", ""))\nend\n\nreturn M\n');
  return anvim;
}

const send = async (text: string) => {
  await anvim!.ui.input(text);
  await anvim!.ui.exec_lua(`require("blink.cmp").hide()`);
  await anvim!.ui.waitFor(() => anvim!.ui.exec_lua(`return not require("blink.cmp").is_menu_visible()`));
  await anvim!.ui.input("<CR>");
};

// The rows of the transcript window, as text.
const rows = (lines: string[], box: Box) =>
  lines.slice(box.row, box.row + box.height).map((line) => cells(line, box.col, box.width).trimEnd());

const hlNames = (row: number, col: number) =>
  anvim!.ui.attrs.get(anvim!.ui.grid[row]![col]!.hl)?.names.split("+") ?? [];

test("the todo list stays under the newest output, updates in place, and draws no tool lines", async () => {
  const { ui } = await tasksSession();
  const box = await anvim!.box("transcript");
  const mark = ui.mark();
  await send("Track these steps");
  await ui.waitFor("% context", 20000);
  const frames = ui.frames(mark);
  const open = frames.filter((f) => rows(f.lines, box).some((r) => /Todos · [012] of 3 done/.test(r)));
  expect(open.length).toBeGreaterThan(0);
  for (const f of open) {
    const r = rows(f.lines, box);
    const head = r.findIndex((line) => line.includes("Todos ·"));
    // The list's three items, then nothing.
    expect(r.slice(head + 1, head + 4).every((line) => /^ +(⎿ +)?[☐☒] /.test(line))).toBe(true);
    expect(r.slice(head + 4).every((line) => line === "")).toBe(true);
  }
  for (const f of frames) {
    expect(rows(f.lines, box).some((line) => /^⏺ Task(Create|Update|List|Get)/.test(line))).toBe(false);
  }
  // The spinner names the task in progress.
  expect(frames.some((f) => f.lines.some((line) => line.includes("Listing .lua files")))).toBe(true);
  // Done, the list stays where it was, above what came after it.
  const done = rows(ui.lines(), box);
  const list = done.findIndex((line) => line.includes("⏺ Todos · 3 of 3 done"));
  const reply = done.findIndex((line) => line.startsWith("⏺ I tracked the three steps"));
  expect(list).toBeGreaterThan(-1);
  expect(reply).toBeGreaterThan(list);
  expect(done.slice(list + 1, list + 4)).toEqual([
    "  ⎿  ☒ Count lines of notes.lua with wc",
    "     ☒ List .lua files with Explore agent",
    "     ☒ Explain what util.lua does",
  ]);
});

test("Claude's markdown renders, while tool lines keep their markers", async () => {
  const { ui } = await tasksSession();
  await send("Track these steps");
  await ui.waitFor("% context", 20000);
  await ui.exec_lua(`
    local t = require("anvim.transcript")
    t.tool_start("md1", "Bash")
    t.tool_use({ id = "md1", name = "Bash", input = { command = "grep -n '**' *.lua src/__init__.py" } })
    t.tool_result({ id = "md1", is_error = false, text = "", result = { stdout = "a.lua:3: \`x\` **y** __init__" } })
  `);
  await ui.waitFor("Bash(grep -n '**' *.lua src/__init__.py)");
  const box = await anvim!.box("transcript");
  const r = rows(ui.lines(), box);
  // Markers and fence lines are hidden in Claude's text.
  const count = r.findIndex((line) => line.includes("1. Line count: notes.lua has 16 lines."));
  expect(count).toBeGreaterThan(-1);
  expect(r.some((line) => line.includes("```") || line.includes("**Line"))).toBe(false);
  const col = box.col + [...r[count]!].indexOf("L");
  expect(hlNames(box.row + count, col)).toContain("@markup.strong");
  // The code block has Lua colors.
  const code = r.findIndex((line) => line.trim() === "function M.trim(s)");
  expect(code).toBeGreaterThan(-1);
  const fnCol = box.col + [...r[code]!].indexOf("f");
  expect(hlNames(box.row + code, fnCol)).toContain("Keyword");
  // A tool line and its result are not markdown.
  expect(r).toContain("  ⎿  a.lua:3: `x` **y** __init__");
  const tool = r.findIndex((line) => line.startsWith("⏺ Bash(grep"));
  const starCol = box.col + [...r[tool]!].indexOf("*");
  expect(hlNames(box.row + tool, starCol).some((name) => name.startsWith("@markup"))).toBe(false);
});

test("a subagent's last tool calls show under it while it runs, then fold into its result", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "tool_start", id = "ag1", name = "Agent" })
    sidecar.dispatch({ type = "tool_use", id = "ag1", name = "Agent",
      input = { description = "Find the matcher", subagent_type = "Explore", prompt = "..." } })
    for i, file in ipairs({ "a.lua", "b.lua", "c.lua", "d.lua" }) do
      sidecar.dispatch({ type = "tool_use", id = "c" .. i, name = "Read", parent_id = "ag1",
        input = { file_path = vim.fn.getcwd() .. "/" .. file } })
    end
  `);
  await ui.waitFor("+1 more tool use");
  const box = await anvim.box("transcript");
  let r = rows(ui.lines(), box);
  const head = r.indexOf("⏺ Explore(Find the matcher)");
  expect(r.slice(head, head + 5)).toEqual([
    "⏺ Explore(Find the matcher)",
    "  ⎿  Read(b.lua)",
    "     Read(c.lua)",
    "     Read(d.lua)",
    "     +1 more tool use",
  ]);
  await ui.exec_lua(`
    require("anvim.sidecar").dispatch({ type = "tool_result", id = "ag1", is_error = false,
      text = "done", result = { totalToolUseCount = 4, totalTokens = 1234, totalDurationMs = 61500 } })
  `);
  await ui.waitFor("Done (4 tool uses · 1.2k tokens · 1m 1s)");
  r = rows(ui.lines(), box);
  expect(r.slice(head, head + 3)).toEqual(["⏺ Explore(Find the matcher)", "  ⎿  Done (4 tool uses · 1.2k tokens · 1m 1s)", ""]);
});
