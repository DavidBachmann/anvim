// Permission prompts with keys at a user's pace, so the 0.4 s guard is on.
// The pauses are part of what the user does.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, cells, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const allow = (req: number) => [{ type: "permission_response", req, behavior: "allow" }];

// A Bash request, the way the sidecar sends it.
function ask(req: number, command: string) {
  return anvim!.ui.exec_lua(
    `
    local req, command = ...
    local sidecar, id, input = require("anvim.sidecar"), "pq" .. req, { command = command }
    sidecar.dispatch({ type = "tool_start", id = id, name = "Bash" })
    sidecar.dispatch({ type = "tool_use", id = id, name = "Bash", input = input })
    sidecar.dispatch({ type = "permission_request", req = req, tool_use_id = id, tool = "Bash", input = input })
  `,
    req,
    command,
  );
}

// The prompt's text on the screen, after "❯ ".
async function promptText() {
  const input = await anvim!.box("input");
  return cells(anvim!.ui.lines()[input.row + 1]!, input.col + 2, input.width - 2).trimEnd();
}

const hideMenu = () => anvim!.hideMenu();

test("a replayed request: prose, digits and enter typed in insert mode never answer, and esc, a pause and 1 allow", async () => {
  // The recording ends with the request, so the replay waits for the answer.
  anvim = await start({
    recording: "permission-session.jsonl",
    frames: (frames) => frames.slice(0, frames.findIndex((f) => f.includes(`"type":"permission_request"`)) + 1),
    env: { ANVIM_MODE: "default" },
  });
  const { ui } = anvim;
  await anvim.capture();
  await anvim.type("Add a comment");
  await ui.input("<CR>");
  await ui.waitFor("Do you want to make this edit to matchparen.lua?", 20000);
  await ui.waitFor("1. Yes");
  const prose = "also fix the test in step 2";
  await anvim.type(prose);
  await hideMenu();
  await ui.input("<CR>");
  await ui.drain();
  expect(await anvim.answers()).toEqual([]);
  expect(await promptText()).toBe(prose);
  expect(ui.screen()).toContain("Do you want to make this edit to matchparen.lua?");
  await anvim.waitWhere("input", "i");

  // Twice the guard, so that a slow machine cannot shorten the pause.
  await ui.input("<Esc>");
  await Bun.sleep(800);
  await ui.input("1");
  await ui.waitFor(async () => (await anvim!.answers()).length > 0);
  expect(await anvim.answers()).toEqual(allow(1));
  await ui.waitFor(() => !ui.screen().includes("Do you want to make this edit"));
  // Typing goes on where it stopped.
  await anvim.waitWhere("input", "i");
  const input = await anvim.box("input");
  await ui.waitFor(() => ui.cursor.row === input.row + 1 && ui.cursor.col === input.col + 2 + prose.length);
  expect(await promptText()).toBe(prose);
});

test("the hint follows the mode, and esc, a pause and enter choose the highlighted choice", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await anvim.insert();
  await anvim.type("ship it");
  await ask(80, "make deploy");
  await ui.waitFor("Do you want to proceed?");
  await ui.waitFor("To answer: esc to leave insert mode, then 1-2 or enter");
  await Bun.sleep(1000);
  await hideMenu();
  await ui.input("<Esc>");
  await ui.waitFor("To answer: 1-2, or j/k and enter");
  expect(ui.screen()).not.toContain("esc to leave insert mode");
  await anvim.waitWhere("input", "n");
  await Bun.sleep(150);
  await ui.input("<CR>");
  await ui.waitFor(async () => (await anvim!.answers()).length > 0);
  expect(await anvim.answers()).toEqual(allow(80));
  await ui.waitFor(() => !ui.screen().includes("Do you want to proceed?"));
});

test("the hint says to go to the prompt while the cursor is elsewhere", async () => {
  anvim = await start();
  const { ui } = anvim;
  const here = "To answer: 1-2, or j/k and enter";
  const away = "To answer: go to the prompt, then 1-2 or enter";
  await ask(82, "make deploy");
  await ui.waitFor(here);
  await ui.input("<C-w>h");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(away);
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.waitFor(here);
  // The key view covers the activity line, and it closes with window hops
  // that fire no autocmds.
  await ui.input("<Space>?");
  await anvim.waitWhere("anvim_keys", "n");
  expect(await ui.exec_lua<string>(`return require("anvim.permission").hint()`)).toBe(away);
  await ui.input("q");
  await anvim.waitWhere("input", "n");
  await ui.waitFor(here);
  await ui.input("<C-g>");
  await ui.waitFor(async () => (await ui.exec_lua<boolean>(`return require("anvim.compose").win() ~= nil`)) === true);
  await ui.waitFor(away);
  await ui.input("<C-g>");
  await anvim.waitWhere("input", "n");
  await ui.waitFor(here);
});

test("j, a pause and enter choose the next choice", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await ask(81, "make deploy");
  await ui.waitFor("Do you want to proceed?");
  await anvim.waitWhere("input", "n");
  await Bun.sleep(800);
  await ui.input("j");
  await ui.waitFor("❯ 2. No");
  await ui.input("<CR>");
  // No means typing what to do instead.
  await ui.waitFor("Type what to do instead");
  await anvim.waitWhere("input", "i");
  expect(await anvim.answers()).toEqual([]);
});

test("enter held down in insert mode never answers", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await anvim.insert();
  // Key repeat at 30 Hz, and the request opens at 0.3 s.
  const t0 = Date.now();
  let opened = false;
  while (Date.now() - t0 < 1200) {
    if (!opened && Date.now() - t0 > 300) {
      await ask(79, "git push --force");
      opened = true;
    }
    await ui.input("<CR>");
    await Bun.sleep(33);
  }
  await ui.drain();
  expect(await anvim.answers()).toEqual([]);
  await ui.waitFor("Do you want to proceed?");
  await anvim.waitWhere("input", "i");
});

test("1 right after the last typed character does not answer, and 1 after a pause allows", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await anvim.insert();
  await anvim.type("draft text");
  await ask(7, "make");
  await ui.waitFor("Do you want to proceed?");
  // Past the guard that starts when the request opens.
  await Bun.sleep(600);
  await anvim.type("ab", 70);
  await hideMenu();
  await ui.input("<Esc>");
  await Bun.sleep(50);
  await ui.input("1");
  await ui.drain();
  expect(await anvim.answers()).toEqual([]);
  expect(ui.screen()).toContain("Do you want to proceed?");
  await Bun.sleep(800);
  await ui.input("1");
  await ui.waitFor(async () => (await anvim!.answers()).length > 0);
  expect(await anvim.answers()).toEqual(allow(7));
  await ui.waitFor(() => !ui.screen().includes("Do you want to proceed?"));
  await anvim.waitWhere("input", "i");
  const input = await anvim.box("input");
  await ui.waitFor(() => inBox(ui.cursor, input) && ui.cursor.col === input.col + 2 + "draft textab".length);
  expect(await promptText()).toBe("draft textab");
});

test("a no with a reason after a click away leaves the prompt where typing stopped", async () => {
  anvim = await start();
  const { ui } = anvim;
  const prompt = () => ui.exec_lua<string>(`return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, 1, false)[1]`);
  await anvim.toCode();
  const code = await anvim.box("code");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await anvim.insert();
  await anvim.type("hello");
  await ui.inputMouse("left", "press", code.row + 2, code.col + 14);
  await ui.inputMouse("left", "release", code.row + 2, code.col + 14);
  await anvim.waitWhere("code", "n");
  await ask(1, "ls");
  await ui.waitFor("1. Yes");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await Bun.sleep(800);
  await ui.input("2");
  await anvim.waitWhere("input", "i");
  await anvim.type("no");
  await hideMenu();
  // The guard: a pause after the last typed character.
  await Bun.sleep(500);
  await ui.input("<CR>");
  await anvim.waitWhere("input", "n");
  await ui.drain();
  expect(await prompt()).toBe("hello");
  await anvim.insert();
  await anvim.type("!");
  expect(await prompt()).toBe("hello!");
});
