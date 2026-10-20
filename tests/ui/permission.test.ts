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

// blink.cmp may show its menu while the user types prose, and <CR> would take
// an item there.
const hideMenu = () => anvim!.ui.exec_lua(`require("blink.cmp").hide()`);

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

test("esc, a pause and enter never answer, the habit of sending a prompt; j, k and enter do", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await anvim.type("ship it");
  await ask(80, "make deploy");
  await ui.waitFor("Do you want to proceed?");
  await Bun.sleep(1000);
  await hideMenu();
  await ui.input("<Esc>");
  await Bun.sleep(150);
  await ui.input("<CR>");
  await ui.drain();
  expect(await anvim.answers()).toEqual([]);
  expect(ui.screen()).toContain("Do you want to proceed?");
  await ui.input("jk");
  await ui.drain();
  await ui.input("<CR>");
  await ui.waitFor(async () => (await anvim!.answers()).length > 0);
  expect(await anvim.answers()).toEqual(allow(80));
  await ui.waitFor(() => !ui.screen().includes("Do you want to proceed?"));
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
