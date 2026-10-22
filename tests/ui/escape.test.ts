// Esc in the prompt acts only on a second press after a pause, so that a
// burst of Esc presses, as from a capslock mapped to Esc, never stops Claude.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const sent = (type: string) =>
  anvim!.ui.exec_lua<number>(
    `
    local type = ...
    return #vim.tbl_filter(function(msg)
      return msg.type == type
    end, _G.anvim_sent)
  `,
    type,
  );

// The group names of the first cell of `text` on the screen, and its row.
function groupsOf(text: string): { row: number; names: string[] } | undefined {
  const { ui } = anvim!;
  const lines = ui.lines();
  for (let row = 0; row < lines.length; row++) {
    const at = lines[row]!.indexOf(text);
    if (at < 0) continue;
    // Each glyph on these rows is one cell wide.
    const cell = ui.grid[row]![[...lines[row]!.slice(0, at)].length]!;
    return { row, names: (ui.attrs.get(cell.hl)?.names ?? "").split("+") };
  }
}

// The groups of the prompt's winbar, as Neovim evaluates it.
const winbarGroups = () =>
  anvim!.ui.exec_lua<string[]>(`
    local win = require("anvim.layout").wins.input
    local bar = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, highlights = true })
    return vim.tbl_map(function(h)
      return h.group
    end, bar.highlights)
  `);

const has = (lines: string[], text: string) => lines.some((line) => line.includes(text));

test("a burst of esc from insert mode never stops Claude, and esc, a pause and esc do", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  // A long limit, so that a slow machine cannot end it before the checks.
  await ui.exec_lua(`require("anvim.input").esc_limit_ms = 10000`);
  await ui.exec_lua(`require("anvim.input").set_busy(true)`);
  await ui.waitFor("esc twice to stop)");
  await anvim.insert();
  await anvim.type("draft");
  await anvim.hideMenu();

  const mark = ui.mark();
  for (let i = 0; i < 10; i++) {
    await ui.input("<Esc>");
    await Bun.sleep(50);
  }
  await ui.drain();
  expect(await sent("interrupt")).toBe(0);
  await anvim.waitWhere("input", "n");
  await ui.waitFor(() => ui.frames(mark).some((f) => has(f.lines, "esc again to stop Claude")));
  // The spinner's line gives way to the red text.
  const last = ui.frames(mark).at(-1)!;
  expect(has(last.lines, "esc again to stop Claude")).toBe(true);
  expect(has(last.lines, "esc twice to stop)")).toBe(false);
  expect(groupsOf("esc again to stop Claude")?.names).toContain("DiagnosticError");
  expect(await winbarGroups()).toContain("AnvimDanger");

  // Twice the pause, so that a slow machine cannot shorten it.
  await Bun.sleep(800);
  const stop = ui.mark();
  await ui.input("<Esc>");
  await ui.waitFor(async () => (await sent("interrupt")) === 1);
  await ui.waitFor(() => ui.frames(stop).some((f) => !has(f.lines, "esc again to stop Claude")));
  expect(await ui.exec_lua(`return require("anvim.input").armed() == nil`)).toBe(true);
  expect(await sent("interrupt")).toBe(1);
});

// A Bash request, the way the sidecar sends it, with the cursor in the prompt
// past the guard that starts when the request opens.
async function ask(req: number) {
  const { ui } = anvim!;
  await ui.exec_lua(
    `
    local req = ...
    local sidecar, id, input = require("anvim.sidecar"), "esc" .. req, { command = "make" }
    sidecar.dispatch({ type = "tool_start", id = id, name = "Bash" })
    sidecar.dispatch({ type = "tool_use", id = id, name = "Bash", input = input })
    sidecar.dispatch({ type = "permission_request", req = req, tool_use_id = id, tool = "Bash", input = input })
  `,
    req,
  );
  await ui.waitFor("Do you want to proceed?");
  await anvim!.waitWhere("input", "n");
  await Bun.sleep(800);
}

test("for a request, esc arms with red text and a red choice, and esc after a pause answers No", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await ui.exec_lua(`require("anvim.input").esc_limit_ms = 10000`);
  await ask(5);
  const mark = ui.mark();
  await ui.input("<Esc>");
  await ui.waitFor(() => ui.frames(mark).some((f) => has(f.lines, "esc again to answer No")));
  await ui.drain();
  expect(await anvim.answers()).toEqual([]);
  expect(groupsOf("esc again to answer No")?.names).toContain("DiagnosticError");
  expect(groupsOf("2. No, and tell Claude")?.names).toContain("DiagnosticError");
  await Bun.sleep(800);
  await ui.input("<Esc>");
  await ui.waitFor(async () => (await anvim!.answers()).length > 0);
  expect(await anvim.answers()).toEqual([{ type: "permission_response", req: 5, behavior: "deny" }]);
});

test("the red text and the red choice go at the end of the time limit, without a key", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.capture();
  await ui.exec_lua(`require("anvim.input").esc_limit_ms = 1000`);
  await ask(6);
  const mark = ui.mark();
  await ui.input("<Esc>");
  // Nothing else redraws the screen meanwhile, so the timer must.
  await ui.waitFor(() => {
    const frames = ui.frames(mark);
    const shown = frames.findIndex((f) => has(f.lines, "esc again to answer No"));
    return shown >= 0 && frames.slice(shown).some((f) => !has(f.lines, "esc again to answer No"));
  }, 5000);
  await ui.drain();
  expect(ui.screen()).toContain("To answer: 1-2, or j/k and enter");
  expect(groupsOf("2. No, and tell Claude")?.names ?? []).not.toContain("DiagnosticError");
  expect(await anvim.answers()).toEqual([]);
});
