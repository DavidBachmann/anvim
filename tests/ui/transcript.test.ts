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
  await anvim!.hideMenu();
  await anvim!.ui.input("<CR>");
};

// The rows of the transcript window, as text, without the time at the end of an item's row.
const rows = (lines: string[], box: Box) =>
  lines
    .slice(box.row, box.row + box.height)
    .map((line) => cells(line, box.col, box.width).replace(/ +\d\d:\d\d:\d\d$/, "").trimEnd());

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
  // The code block has Lua colors. A colorscheme can link the capture to Keyword.
  const code = r.findIndex((line) => line.trim() === "function M.trim(s)");
  expect(code).toBeGreaterThan(-1);
  const fnCol = box.col + [...r[code]!].indexOf("f");
  const fnNames = hlNames(box.row + code, fnCol);
  expect(fnNames.some((name) => name === "Keyword" || name.startsWith("@keyword")), fnNames.join("+")).toBe(true);
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

// The time that items show, of the clock that CLOCK sets.
const TIME = "09:05:07";
const CLOCK = `
  require("anvim.transcript").clock = function()
    return os.time({ year = 2026, month = 10, day = 22, hour = 9, min = 5, sec = 7 })
  end
`;

test("an item's time shows dim at the right edge, after a wrapped line's end, and covers no text", async () => {
  anvim = await start();
  const { ui } = anvim;
  const box = await anvim.box("transcript");
  await ui.exec_lua(CLOCK);
  await ui.exec_lua(
    `
    local width = ...
    local sidecar = require("anvim.sidecar")
    local transcript = require("anvim.transcript")
    transcript.user("Short prompt")
    sidecar.dispatch({ type = "text_start" })
    sidecar.dispatch({ type = "text_delta", text = ("word "):rep(math.floor(width / 3)) .. "end." })
    sidecar.dispatch({ type = "text_stop" })
    transcript.notice("warn", ("x"):rep(width - 2))
    sidecar.dispatch({ type = "tool_start", id = "tu_a1", name = "Agent" })
    sidecar.dispatch({ type = "tool_use", id = "tu_a1", name = "Agent", input = { description = "Read a1", subagent_type = "Explore" } })
    sidecar.dispatch({ type = "agent_start", agent_id = "a1", tool_use_id = "tu_a1", description = "Read a1",
      subagent_type = "Explore", depth = 1, background = false })
    require("anvim.follow").set_focus("a1")
  `,
    box.width,
  );
  await ui.waitFor("◉ focused");
  const r = ui.lines().slice(box.row, box.row + box.height).map((line) => cells(line, box.col, box.width));
  const at = (prefix: string) => {
    const row = r.findIndex((line) => line.startsWith(prefix));
    expect(row, r.join("\n")).toBeGreaterThan(-1);
    return row;
  };

  // A short row: the text, then the time in the last cells, in AnvimTime's color.
  const prompt = at("❯ Short prompt");
  expect(r[prompt]!.endsWith(TIME)).toBe(true);
  const rgb = (row: number, col: number) => ui.attrs.get(ui.grid[box.row + row]![box.col + col]!.hl)?.rgb ?? {};
  const fg = await ui.exec_lua<number>(`return vim.api.nvim_get_hl(0, { name = "AnvimTime", link = false }).fg`);
  expect(rgb(prompt, box.width - 1).foreground).toBe(fg);
  // The prompt's band shows through it.
  expect(rgb(prompt, box.width - 1).background).toBe(rgb(prompt, 2).background);

  // A wrapped line: the first row keeps all its text, and the time goes after the last row's text.
  const text = at("⏺ word");
  const end = r.findIndex((line, i) => i > text && line.includes("end."));
  expect(end).toBeGreaterThan(text);
  expect(r.slice(text, end).some((line) => line.includes(TIME))).toBe(false);
  expect(r[end]!.endsWith(TIME)).toBe(true);
  const words = r.slice(text, end + 1).join(" ").replace(TIME, "").trim().split(/\s+/);
  expect(words).toEqual(["⏺", ...Array(Math.floor(box.width / 3)).fill("word"), "end."]);

  // A row whose text reaches the right edge keeps all of it.
  const full = at("⚠ x");
  expect(r[full]).toBe(`⚠ ${"x".repeat(box.width - 2)}`);

  // A focused agent's line shows both its mark and the time.
  const agent = at("⏺ Explore(Read a1)");
  expect(r[agent]!).toMatch(new RegExp(`^⏺ Explore\\(Read a1\\) ◉ focused +${TIME}$`));

  // Where both do not fit, the mark shows and the time does not.
  const long = "x".repeat(box.width - 26);
  await ui.exec_lua(
    `
    local long = ...
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "tool_start", id = "tu_a2", name = "Agent" })
    sidecar.dispatch({ type = "tool_use", id = "tu_a2", name = "Agent", input = { description = long, subagent_type = "Explore" } })
    sidecar.dispatch({ type = "agent_start", agent_id = "a2", tool_use_id = "tu_a2", description = long,
      subagent_type = "Explore", depth = 1, background = false })
    require("anvim.follow").set_focus("a2")
  `,
    long,
  );
  await ui.waitFor(() => ui.screen().includes(`(${long}) ◉ focused`));
  await ui.drain();
  const now = ui.lines().slice(box.row, box.row + box.height).map((line) => cells(line, box.col, box.width));
  const focused = now.find((line) => line.startsWith(`⏺ Explore(${long})`))!;
  expect(focused.trimEnd()).toBe(`⏺ Explore(${long}) ◉ focused`);
  expect(now.find((line) => line.startsWith("⏺ Explore(Read a1)"))!).toMatch(new RegExp(`^⏺ Explore\\(Read a1\\) +${TIME}$`));
});

test("a tool line keeps its time in every frame through its label, its result and an interrupt", async () => {
  anvim = await start();
  const { ui } = anvim;
  const box = await anvim.box("transcript");
  await ui.exec_lua(CLOCK);
  const mark = ui.mark();
  const send = (lua: string) => ui.exec_lua(`local sidecar = require("anvim.sidecar")\n${lua}`);
  await send(`sidecar.dispatch({ type = "tool_start", id = "tb1", name = "Bash" })`);
  await ui.waitFor("⏺ Bash");
  await send(`sidecar.dispatch({ type = "tool_field", id = "tb1", name = "Bash", key = "command", phase = "end", value = "echo hi" })`);
  await ui.waitFor("⏺ Bash(echo hi)");
  await send(`sidecar.dispatch({ type = "tool_use", id = "tb1", name = "Bash", input = { command = "echo hi" } })`);
  await send(`sidecar.dispatch({ type = "tool_result", id = "tb1", is_error = false, text = "hi", result = { stdout = "hi" } })`);
  await ui.waitFor("⎿  hi");
  await send(`
    sidecar.dispatch({ type = "tool_start", id = "tb2", name = "Bash" })
    sidecar.dispatch({ type = "tool_use", id = "tb2", name = "Bash", input = { command = "sleep 9" } })
  `);
  await ui.waitFor("⏺ Bash(sleep 9)");
  await send(`sidecar.dispatch({ type = "turn_end", subtype = "success", is_error = false, duration_ms = 1, cost_usd = 0 })`);
  await ui.waitFor("⎿  Interrupted");
  await ui.drain();
  const frames = ui.frames(mark);
  expect(frames.length).toBeGreaterThan(3);
  for (const f of frames) {
    const r = f.lines.slice(box.row, box.row + box.height).map((line) => cells(line, box.col, box.width));
    for (const line of r) {
      if (line.startsWith("⏺ Bash")) expect(line.endsWith(TIME), r.join("\n")).toBe(true);
      else expect(line.includes(TIME), r.join("\n")).toBe(false);
    }
  }
});

test("at 120x40 a time shows whole or not at all, in the Claude column and in the Agent Overview", async () => {
  const files = {
    "alpha.js": "// Adds two numbers.\nfunction add(a, b) {\n  return a + b;\n}\n",
    "beta.js": "// Greets a person by name.\nfunction greet(name) {\n  return 'Hello, ' + name;\n}\n",
    "gamma.js": "// Keeps the first n items of a list.\nfunction take(list, n) {\n  return list.slice(0, n);\n}\n",
  };
  anvim = await start({ recording: "overview-session.jsonl", files, cols: 120, rows: 40, env: { ANVIM_REPLAY_SPEED: "8" } });
  const { ui } = anvim;
  // A color of its own tells the times' cells from text.
  await ui.exec_lua(`vim.api.nvim_set_hl(0, "AnvimTime", { fg = "#123456" })`);
  // The times on the screen, from the rows `from` to `to`. Each one must be whole.
  const times = (from = 0, to = ui.grid.length) => {
    const found: string[] = [];
    for (const [row, line] of ui.grid.slice(from, to).entries()) {
      let run = "";
      for (const cell of [...line, { text: " ", hl: 0 }]) {
        if (ui.attrs.get(cell.hl)?.rgb.foreground === 0x123456) {
          run += cell.text;
        } else if (run) {
          expect(run, `row ${from + row}:\n${ui.screen()}`).toMatch(/^\d\d:\d\d:\d\d$/);
          found.push(run);
          run = "";
        }
      }
    }
    return found;
  };

  await anvim.insert();
  await ui.input("List the functions");
  await anvim.hideMenu();
  await ui.input("<CR>");
  await ui.waitFor("% context", 20000);
  await ui.drain();
  // Some of the Agent lines leave too little room, and others show the time.
  expect(times().length).toBeGreaterThan(2);
  expect(ui.screen()).toContain("⏺ Agent(List functions in alpha.js)");

  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  await ui.input(" ca");
  await ui.waitFor(() => ui.screen().includes("Agent Overview"));
  // Each agent's log, in the order of the tabs.
  const seen: string[] = [];
  const shown = () => ui.screen().match(/Read the file named (\w+\.js)/)?.[1];
  for (let i = 0; i < 3; i++) {
    await ui.input("<Tab>");
    await ui.waitFor(() => shown() !== undefined && !seen.includes(shown()!));
    seen.push(shown()!);
    await ui.drain();
    const top = ui.lines().findIndex((line) => line.includes("Agent Overview"));
    const bottom = ui.lines().findIndex((line, i) => i > top && line.includes("╰"));
    expect(times(top, bottom).length, ui.screen()).toBeGreaterThan(1);
  }
  expect(seen.sort()).toEqual(["alpha.js", "beta.js", "gamma.js"]);
});
