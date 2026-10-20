// The session and model pickers, in the user's snacks picker, with keys.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

test("<leader>cs lists this directory's sessions, and enter resumes the chosen one", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    local sessions, sidecar = require("anvim.sessions"), require("anvim.sidecar")
    local now = os.time() * 1000
    sessions.fetch = function(cb)
      cb({
        { id = "11111111-1111-1111-1111-111111111111", title = "Add a comment to matchparen", modified = now - 5 * 60000, size = 40960, branch = "main" },
        { id = "22222222-2222-2222-2222-222222222222", title = "Explain the highlight function", modified = now - 3 * 86400000, size = 2 * 1048576 },
      })
    end
    _G.restarts = {}
    sidecar.restart = function(cmd)
      table.insert(_G.restarts, cmd)
    end
  `);
  await anvim.toCode();
  await anvim.type(" cs", 80);
  await ui.waitFor("Resume a session");
  await ui.waitFor("Explain the highlight function");
  const screen = ui.screen();
  expect(screen).toContain("5 min ago");
  expect(screen).toContain("Add a comment to matchparen");
  expect(screen).toContain("40 KB · main");
  expect(screen).toContain("3 days ago");
  await anvim.type("highlight", 30);
  await ui.waitFor(() => !ui.screen().includes("Add a comment to matchparen"));
  await Bun.sleep(150);
  await ui.input("<CR>");
  await ui.waitFor(async () => (await ui.exec_lua<unknown[]>(`return _G.restarts`)).length === 1);
  const [cmd] = await ui.exec_lua<{ type: string; resume: string; history: boolean }[]>(`return _G.restarts`);
  expect(cmd).toMatchObject({ type: "start", resume: "22222222-2222-2222-2222-222222222222", history: true });
  await ui.waitFor("Resuming session 22222222-2222-2222-2222-222222222222");
});

test("<leader>cm lists Claude Code's models, and the choice reaches the footer", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    local sidecar = require("anvim.sidecar")
    local send = sidecar.send
    _G.sent = {}
    sidecar.send = function(msg)
      table.insert(_G.sent, msg)
      if msg.type == "list_models" then
        vim.schedule(function()
          sidecar.dispatch({ type = "models", models = {
            { value = "default", name = "Default (recommended)", description = "Opus 5.5", resolved = "claude-opus-5-5" },
            { value = "sonnet", name = "Sonnet 5.5", description = "Most efficient for simpler tasks", resolved = "claude-sonnet-5-5" },
            { value = "haiku", name = "Haiku 5.5", description = "Fastest for quick answers", resolved = "claude-haiku-5-5" },
          } })
        end)
        return
      end
      return send(msg)
    end
  `);
  await anvim.toCode();
  await anvim.type(" cm", 80);
  await ui.waitFor("Most efficient for simpler tasks");
  await anvim.type("sonnet", 30);
  await Bun.sleep(200);
  await ui.input("<CR>");
  await ui.waitFor("Set model to Sonnet 5.5");
  await ui.waitFor(() => ui.screen().includes("Sonnet 5.5  "));
  const sent = await ui.exec_lua<{ type: string; model?: string }[]>(`return _G.sent`);
  expect(sent.filter((m) => m.type === "set_model")).toEqual([{ type: "set_model", model: "sonnet" }]);
});

test("a picker that the prompt opens in insert mode gives insert mode back, also after a cancel", async () => {
  anvim = await start();
  const { ui } = anvim;
  await ui.exec_lua(`
    local sessions, sidecar = require("anvim.sessions"), require("anvim.sidecar")
    sessions.fetch = function(cb)
      cb({ { id = "11111111-1111-1111-1111-111111111111", title = "Add a comment to matchparen", modified = os.time() * 1000 } })
    end
    local send = sidecar.send
    _G.sent = {}
    sidecar.send = function(msg)
      table.insert(_G.sent, msg)
      if msg.type == "list_models" then
        vim.schedule(function()
          sidecar.dispatch({ type = "models", models = {
            { value = "haiku", name = "Haiku 5.5", description = "Fastest for quick answers", resolved = "claude-haiku-5-5" },
          } })
        end)
      elseif msg.type ~= "set_effort" then
        return send(msg)
      end
    end
  `);
  const sent = (type: string) =>
    ui.exec_lua<{ type: string; effort?: string }[]>(
      `local t = ... return vim.tbl_filter(function(m) return m.type == t end, _G.sent)`,
      type,
    );
  // Enter on the menu's row sends the command, as in Claude Code.
  const run = async (command: string, title: string) => {
    await anvim!.type(command, 30);
    await Bun.sleep(200);
    await ui.input("<CR>");
    await ui.waitFor(title);
    await Bun.sleep(200);
  };

  await anvim.insert();
  await run("/effort", "default (your settings, else the model's)");
  await anvim.type("high", 30);
  await Bun.sleep(200);
  await ui.input("<CR>");
  await anvim.waitWhere("input", "i");
  expect(await sent("set_effort")).toEqual([{ type: "set_effort", effort: "high" }]);

  await run("/model", "Fastest for quick answers");
  await ui.input("<C-c>");
  await anvim.waitWhere("input", "i");

  await run("/resume", "Add a comment to matchparen");
  await ui.input("<C-c>");
  await anvim.waitWhere("input", "i");
  await anvim.type("still typing", 30);
  await ui.waitFor("still typing");

  // From normal mode, the prompt stays in normal mode.
  await ui.input("<Esc>");
  await ui.exec_lua(`vim.api.nvim_buf_set_lines(require("anvim.input").buf(), 0, -1, false, { "/effort" })`);
  await anvim.waitWhere("input", "n");
  await ui.input("<CR>");
  await ui.waitFor("default (your settings, else the model's)");
  await Bun.sleep(200);
  await ui.input("<C-c>");
  await anvim.waitWhere("input", "n");
  expect((await sent("set_effort")).length).toBe(1);
});
