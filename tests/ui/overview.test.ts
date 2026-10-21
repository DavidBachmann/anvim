// The Agent Overview: tabs in the agents' colors, a conversation that grows
// without a key, and <CR> that closes the window and follows the agent.
import { afterEach, expect, test } from "bun:test";
import type { Frame } from "../../tools/screen/ui.ts";
import { type Anvim, cells, cursorIn, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const files = {
  "alpha.js": "// Adds two numbers.\nfunction add(a, b) {\n  return a + b;\n}\n",
  "beta.js": "// Greets a person by name.\nfunction greet(name) {\n  return 'Hello, ' + name;\n}\n",
  "gamma.js": "// Keeps the first n items of a list.\nfunction take(list, n) {\n  return list.slice(0, n);\n}\n",
};

const ALPHA = "a462161d1283697a4";
const BETA = "ac8d35b341c2136a8";

// Plays the fixture with gaps of at most `cap` ms, and two holds: `read` ms
// before the first agent's Read, so that a later frame adds its tool line,
// and a minute before the first agent's text, so that the agents still run.
const holdWith = (read: number, cap: number) => (frames: string[]) => {
  let at = 0;
  let prev: number | null = null;
  let held = false;
  let text = false;
  return frames.map((line) => {
    const space = line.indexOf(" ");
    const t = Number(line.slice(0, space));
    const rest = line.slice(space + 1);
    const ev = JSON.parse(rest);
    let gap = prev === null ? 0 : Math.min(t - prev, cap);
    if (!held && ev.type === "tool_use" && ev.name === "Read" && ev.agent_id === ALPHA) {
      gap = Math.max(gap, read);
      held = true;
    } else if (!text && ev.type === "agent_text") {
      gap = 60000;
      text = true;
    }
    prev = t;
    at += gap;
    return `${at} ${rest}`;
  });
};
const hold = holdWith(4000, 30);

// The frames whose Overview shows a blank tab row, or a rule without its
// title: each row between the top border and the rule must be a tab.
const torn = (frames: Frame[]) =>
  frames.filter((f) => {
    const top = f.lines.findIndex((line) => line.includes("Agent Overview"));
    if (top < 0) return false;
    let row = top + 1;
    while (/│ [⏺◉] /.test(f.lines[row] ?? "")) row++;
    const rule = f.lines[row] ?? "";
    return !(rule.includes("│─ ") && rule.includes(" · "));
  });

// The cell row of the statusline, under it the command line.
const statusline = (f: Frame) => f.lines.at(-2) ?? "";

// Each layout window's place and size, the number of splits and tab pages.
const LAYOUT = `
  local ret = {}
  for role, w in pairs(require("anvim.layout").wins) do
    if vim.api.nvim_win_is_valid(w) then
      local pos = vim.api.nvim_win_get_position(w)
      ret[#ret + 1] = ("%s %d,%d %dx%d"):format(role, pos[1], pos[2], vim.api.nvim_win_get_width(w), vim.api.nvim_win_get_height(w))
    end
  end
  table.sort(ret)
  local splits = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    splits = splits + (vim.api.nvim_win_get_config(w).relative == "" and 1 or 0)
  end
  return table.concat(ret, " ") .. (" splits=%d tabs=%d"):format(splits, #vim.api.nvim_list_tabpages())
`;

const isOpen = () =>
  anvim!.ui.exec_lua<boolean>(`
    local p = require("anvim.overview").get()
    return p ~= nil and p.list.win:win_valid() and p.preview.win:win_valid()
  `);

test("tabs in the agents' colors, a live conversation, and <CR> that follows the agent", async () => {
  anvim = await start({ recording: "overview-session.jsonl", files, frames: hold, env: { ANVIM_REPLAY_SPEED: "1" } });
  const { ui } = anvim;
  const transcript = await anvim.box("transcript");
  await anvim.insert();
  await ui.input("List the functions");
  await anvim.hideMenu();
  await ui.input("<CR>");
  // The first hold: three agents run, and the first one has not read yet.
  await ui.waitFor(
    () =>
      ui.exec_lua<boolean>(`
        local a = require("anvim.agents").get(...)
        return #require("anvim.agents").running() == 3 and a.activity == "Reading alpha.js"
      `, ALPHA),
    5000,
  );
  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  const mark = ui.mark();
  await ui.input(" ca");
  await ui.waitFor(async () => ui.screen().includes("Agent Overview") && (await isOpen()));

  // Each tab's name has its agent's color. ext_hlstate names the group that a link ends in.
  const groups = await ui.exec_lua<string[]>(`
    local ret = {}
    for _, name in ipairs({ "AnvimClaude", "AnvimAgent1", "AnvimAgent2", "AnvimAgent3" }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      while hl.link do
        name = hl.link
        hl = vim.api.nvim_get_hl(0, { name = name })
      end
      ret[#ret + 1] = name
    end
    return ret
  `);
  const nameGroup = (text: string) => {
    const lines = ui.lines();
    const row = lines.findIndex((line) => line.includes(text));
    expect(row).toBeGreaterThan(-1);
    const col = [...lines[row]!.slice(0, lines[row]!.indexOf(text))].length + 2;
    return ui.attrs.get(ui.grid[row]![col]!.hl)?.names.split("+").at(-1);
  };
  expect(["◉ Claude", "⏺ Agent 1", "⏺ Agent 2", "⏺ Agent 3"].map(nameGroup)).toEqual(groups);

  // <Tab> shows Agent 1's prompt, and a later frame adds its Read without a key.
  await ui.input("<Tab>");
  await ui.waitFor(() => ui.screen().includes("Read the file named alpha.js"));
  expect(ui.screen()).not.toContain("⏺ Read(alpha.js)");
  const typed = ui.mark();
  await ui.waitFor(() => ui.screen().includes("⏺ Read(alpha.js)"), 8000);
  expect(ui.frames(typed).length).toBeGreaterThan(0);

  // <CR> on Agent 2: the cursor goes to the prompt, which follows Agent 2 into beta.js.
  await ui.input("<Tab>");
  await ui.waitFor(() => ui.screen().includes("Read the file named beta.js"));
  await ui.input("<CR>");
  await anvim.waitWhere("input", "n");
  await ui.waitFor(async () => /◉ (following )?Agent 2/.test(await anvim!.footer()));
  const code = await anvim.box("code");
  await ui.waitFor(() =>
    ui
      .lines()
      .slice(code.row, code.row + code.height)
      .some((line) => cells(line, code.col, code.width).includes("function greet(name)")),
  );
  expect(await isOpen()).toBe(false);
  expect(cursorIn(ui.frames(mark), transcript)).toEqual([]);

  // A resize keeps the window open. The explorer builds its split again then.
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await ui.resize(160, 44);
  await Bun.sleep(500);
  await ui.drain();
  expect(await isOpen()).toBe(true);
  // The explorer's new split shows the list's buffer for a moment, and follow
  // mode stays.
  expect(await ui.exec_lua(`return require("anvim.follow").mode()`)).toBe("follow");
  expect(ui.lines().at(-2)).toContain("FOLLOW");
  await ui.resize(100, 30);
  await Bun.sleep(500);
  await ui.drain();
  expect(await isOpen()).toBe(true);
  // Below 120 columns, the tabs go on top of the conversation.
  const lines = ui.lines();
  const top = lines.findIndex((line) => line.includes("Agent Overview"));
  expect(lines[top + 1]).toContain("Claude");
  expect(lines[top + 3]).toContain("◉ Agent 2");
  await ui.resize(200, 48);
  await Bun.sleep(500);
  await ui.drain();
  expect(await isOpen()).toBe(true);
  await ui.input("q");
  await anvim.waitWhere("input", "n");

  // q gives the cursor back to the window that opened the Overview.
  await anvim.toCode("beta.js");
  const back = ui.mark();
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await ui.input("q");
  await anvim.waitWhere("code", "n");
  expect(await isOpen()).toBe(false);
  expect(cursorIn(ui.frames(back), await anvim.box("transcript"))).toEqual([]);
  expect(await ui.exec_lua(`return require("anvim.follow").focus`)).toBe(BETA);

  // A window key or a click elsewhere closes it, and the cursor stays there.
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await ui.input("<C-l>");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(async () => !(await isOpen()));
  const box = await anvim.box("code");
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.inputMouse("left", "press", box.row + 1, box.col + 10);
  await ui.inputMouse("left", "release", box.row + 1, box.col + 10);
  await anvim.waitWhere("code", "n");
  await ui.waitFor(async () => !(await isOpen()));
  // The explorer's list is a float on its split, and a click there closes it too.
  const tree = await anvim.box("tree");
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.inputMouse("left", "press", tree.row + 1, tree.col + 2);
  await ui.inputMouse("left", "release", tree.row + 1, tree.col + 2);
  await ui.waitFor(async () => !(await isOpen()));
  expect(await ui.exec_lua<boolean>(`return vim.bo.filetype == "snacks_picker_list" and vim.w.snacks_win ~= nil`)).toBe(
    true,
  );
  expect(await ui.exec_lua(`return require("anvim.follow").focus`)).toBe(BETA);
});

// Sends the prompt and waits until the three agents run, in the prompt in normal mode.
async function agents() {
  const { ui } = anvim!;
  await anvim!.insert();
  await ui.input("List the functions");
  await anvim!.hideMenu();
  await ui.input("<CR>");
  await ui.waitFor(() => ui.exec_lua<boolean>(`return #require("anvim.agents").running() == 3`), 8000);
  await ui.input("<Esc>");
  await anvim!.waitWhere("input", "n");
}

test("<C-w>H, L and T keep the Overview's floats in their place", async () => {
  anvim = await start({ recording: "overview-session.jsonl", files, frames: hold, env: { ANVIM_REPLAY_SPEED: "1" } });
  const { ui } = anvim;
  await agents();
  const layout = await ui.exec_lua<string>(LAYOUT);
  expect(layout).toContain("tabs=1");
  for (const where of ["list", "log", "transcript"]) {
    for (const keys of ["<C-w>L", "<C-w>H", "<C-w>T"]) {
      await ui.input(" ca");
      await ui.waitFor(isOpen);
      await anvim.waitWhere("snacks_picker_list", "n");
      if (where !== "list") {
        // A log, or Claude's conversation, which shows the transcript buffer.
        await ui.input(where === "log" ? "1" : "0");
        await ui.drain();
        await Bun.sleep(100);
        await ui.input("<a-w>");
        await ui.waitFor(() => ui.exec_lua<boolean>(`return vim.w.snacks_picker_preview == true`));
      }
      const before = await ui.exec_lua<number>(`return vim.api.nvim_get_current_win()`);
      await ui.input(keys);
      await ui.drain();
      await Bun.sleep(100);
      await ui.drain();
      const what = `${keys} in the ${where}`;
      expect([what, await ui.exec_lua<string>(LAYOUT)]).toEqual([what, layout]);
      const after = [what, await ui.exec_lua<number>(`return vim.api.nvim_get_current_win()`), await isOpen()];
      expect(after).toEqual([what, before, true]);
      await ui.input("q");
      await anvim.waitWhere("input", "n");
    }
  }
});

test("read mode from the Overview's Claude tab shows no frame of follow mode in the transcript", async () => {
  anvim = await start({ recording: "overview-session.jsonl", files, frames: hold, env: { ANVIM_REPLAY_SPEED: "1" } });
  const { ui } = anvim;
  await agents();
  const transcript = await anvim.box("transcript");
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  await anvim.waitWhere("snacks_picker_list", "n");
  const mark = ui.mark();
  // The preview shows the transcript buffer, so the transcript window shows
  // the buffer of a float on top. It is no copy of that float.
  await ui.input(" cr");
  await anvim.waitWhere("transcript", "n");
  await ui.waitFor(async () => !(await isOpen()));
  await ui.drain();
  const frames = ui.frames(mark).filter((f) => inBox(f.cursor, transcript));
  expect(frames.length).toBeGreaterThan(0);
  expect(frames.filter((f) => statusline(f).includes("FOLLOW")).map(statusline)).toEqual([]);
});

test("the narrow tab list grows and shrinks without a torn frame", async () => {
  anvim = await start({
    recording: "overview-session.jsonl",
    files,
    frames: holdWith(0, 300),
    env: { ANVIM_REPLAY_SPEED: "1" },
    cols: 100,
    rows: 30,
  });
  const { ui } = anvim;
  await anvim.insert();
  await ui.input("List the functions");
  await anvim.hideMenu();
  await ui.input("<CR>");
  await ui.input("<Esc>");
  await anvim.waitWhere("input", "n");
  const mark = ui.mark();
  await ui.input(" ca");
  await ui.waitFor(isOpen);
  expect(await ui.exec_lua<number>(`return #require("anvim.agents").running()`)).toBeLessThan(3);
  await ui.waitFor(() => ui.screen().includes("⏺ Agent 3"), 8000);
  await ui.drain();
  // The statusline shows the list's cursor as row:col. A find would put the
  // cursor on Claude's row, 1:1, for a frame or two.
  await ui.input("2");
  await ui.waitFor(() => / 3:1 *$/.test(statusline({ lines: ui.lines() } as Frame)));
  const selected = ui.mark();
  // An agent ends, and the next prompt drops its tab.
  await ui.exec_lua(
    `require("anvim.sidecar").dispatch({ type = "agent_end", agent_id = ..., status = "completed", summary = "add" })`,
    ALPHA,
  );
  await ui.waitFor(() => ui.screen().includes("done · List functions in alpha.js"));
  await ui.exec_lua(`require("anvim.agents").prompt_sent()`);
  await ui.waitFor(() => !ui.screen().includes("done · List functions in alpha.js"));
  await ui.drain();
  await Bun.sleep(100);
  // snacks draws a new picker in steps, so the check starts at its first whole frame.
  const all = ui.frames(mark);
  const first = all.findIndex((f) => f.lines.some((line) => line.includes("Agent Overview")) && torn([f]).length === 0);
  const frames = all.slice(first);
  expect([first >= 0, frames.length > 3]).toEqual([true, true]);
  expect(torn(frames).map((f) => f.lines.slice(0, 12).join("\n"))).toEqual([]);
  const places = ui.frames(selected).map((f) => statusline(f).trim().split(/ +/).at(-1));
  expect(places).toContain("2:1");
  expect(places.filter((place) => place === "1:1")).toEqual([]);
  expect(await ui.exec_lua(`return require("anvim.overview").get():current().agent_id`)).toBe(BETA);
});
