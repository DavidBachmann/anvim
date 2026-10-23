// Permission prompts with keys at a user's pace, so the 0.4 s guard is on.
// The pauses are part of what the user does.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

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
