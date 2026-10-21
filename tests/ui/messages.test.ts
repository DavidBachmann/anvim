// Neovim's own command line shows the messages. Language servers report their
// progress, and nothing shows it. anvim's notices and multi-line notifications
// go to snacks' notifier, and ask for no Enter.
import { afterEach, expect, test } from "bun:test";
import { join } from "node:path";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// lua_ls reports progress for a workspace with a root marker and enough files.
const workspace = () => {
  const files: Record<string, string> = { ".luarc.json": "{}\n" };
  const body = Array.from({ length: 100 }, (_, i) => `local v${i} = { name = "v${i}", n = ${i} }`).join("\n");
  for (let i = 0; i < 400; i++) files[`lib/m${i}.lua`] = `${body}\nreturn v1\n`;
  return files;
};

test("no LSP progress shows while lua_ls loads a file that Claude reads", async () => {
  anvim = await start({ files: workspace() });
  const { ui } = anvim;
  await ui.exec_lua(`
    _G.progress = {}
    vim.api.nvim_create_autocmd("LspProgress", {
      callback = function(ev)
        local value = ev.data.params.value
        table.insert(_G.progress, { kind = value.kind, title = value.title, message = value.message })
      end,
    })
  `);
  const mark = ui.mark();
  await ui.exec_lua(
    `require("anvim.sidecar").dispatch({ type = "tool_use", id = "r1", name = "Read", input = { file_path = ... } })`,
    join(anvim.dir, "matchparen.lua"),
  );
  await ui.waitFor("local function char_at");
  type Progress = { kind: string; title?: string; message?: string };
  // lua_ls loads and diagnoses the workspace, and ends each report. The
  // LspProgress listener above still gets every report.
  const progress = (await ui.waitFor(
    () =>
      ui.exec_lua<Progress[] | null>(`
        local client = vim.lsp.get_clients({ name = "lua_ls" })[1]
        local ended = vim.iter(_G.progress):any(function(p)
          return p.kind == "end"
        end)
        return ended and client and next(client.progress.pending) == nil and _G.progress or vim.NIL
      `),
    30000,
  )) as Progress[];
  // snacks' notifier draws a notification some time after vim.notify.
  await Bun.sleep(500);
  await ui.drain();
  const titles = [...new Set(progress.flatMap((p) => (p.title ? [p.title] : [])))];
  expect(titles.length).toBeGreaterThan(0);
  const messages = [...new Set(progress.flatMap((p) => (p.message ? [p.message] : [])))];
  const frames = ui.frames(mark);
  expect(frames.length).toBeGreaterThan(0);
  for (const frame of frames) {
    for (const title of titles) expect(frame.lines.filter((l) => l.includes(title))).toEqual([]);
    // The command line, where Neovim shows progress messages.
    const cmdline = frame.lines.at(-1)!.trim();
    for (const message of messages) expect(cmdline).not.toContain(message);
  }
  const history = await ui.exec_lua<string>(`return vim.fn.execute("messages")`);
  for (const title of titles) expect(history).not.toContain(title);
});

test("anvim's notices and a multi-line vim.notify ask for no Enter", async () => {
  anvim = await start();
  const { ui } = anvim;
  // nvim_get_mode answers during a hit-enter prompt, which can hold other
  // requests, so the drain runs in a race with it.
  async function settled(what: string) {
    let done = false;
    const drained = ui.drain().then(() => (done = true));
    const deadline = Date.now() + 5000;
    while (!done && Date.now() < deadline) {
      const mode = await ui.request<{ mode: string; blocking: boolean }>("nvim_get_mode");
      if (mode.mode.startsWith("r")) return `${what}: hit-enter prompt\n${ui.screen()}`;
      await Promise.race([drained, Bun.sleep(50)]);
    }
    await ui.waitFor(() => !ui.screen().includes("Press ENTER"), 500).catch(() => {});
    return ui.screen().includes("Press ENTER") ? `${what}: Press ENTER\n${ui.screen()}` : "ok";
  }

  // The command line shows the typed command, so the last line is upper case.
  await ui.input(`:lua vim.notify("one\\ntwo\\n" .. ("three"):upper(), vim.log.levels.WARN)<CR>`);
  expect(await settled("multi-line notify")).toBe("ok");
  await ui.waitFor("THREE");

  // sessions.command() answers in the transcript, and the yank with a notification.
  await ui.exec_lua(`
    local input = require("anvim.input")
    vim.api.nvim_buf_set_lines(input.buf(), 0, -1, false, { "/ultrareview" })
    input.submit()
  `);
  expect(await settled("/ultrareview")).toBe("ok");
  await ui.waitFor("anvim starts no paid cloud review");
  await ui.exec_lua(`require("anvim.sessions").yank()`);
  expect(await settled("the yank")).toBe("ok");
  await ui.waitFor("Claude has not replied yet");

  await anvim.toCode();
  await ui.input(":w<CR>");
  expect(await settled(":w")).toBe("ok");
  await ui.waitFor("anvim is read-only");
  await ui.input("x");
  expect(await settled("x")).toBe("ok");
  await ui.waitFor("E21");

  await ui.input(":AnvimRestart<CR>");
  expect(await settled(":AnvimRestart")).toBe("ok");
  await ui.waitFor(() => ui.exec_lua<boolean>(`return require("anvim.state").process == "ready"`));
  expect(await settled("the restart")).toBe("ok");
});

test("the command line shows a macro recording, and the statusline does not repeat it", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode();
  const last = await ui.exec_lua<number>(`return vim.o.lines - vim.o.cmdheight`);
  const [cmdline, status] = [() => ui.lines()[last]!, () => ui.lines()[last - 1]!];
  const mark = ui.mark();
  await ui.input("qq");
  await ui.drain();
  await ui.waitFor(() => cmdline().includes("recording @q"), 250);
  // lualine refreshes a frame or more later, so watch a while.
  await Bun.sleep(500);
  await ui.drain();
  expect(ui.frames(mark).filter((f) => f.lines[last - 1]!.includes("recording")).length).toBe(0);
  await ui.input("q");
  await ui.drain();
  await ui.waitFor(() => !cmdline().includes("recording") && !status().includes("recording"), 250);
});

test("an error from a callback during a Write preview stops no frames, and a Space typed after it stays in the prompt", async () => {
  anvim = await start({ recording: "write-session.jsonl", env: { ANVIM_REPLAY_SPEED: "1" } });
  const { ui } = anvim;
  await anvim.insert();
  await anvim.type("x");
  await ui.exec_lua(`require("anvim.sidecar").send({ type = "prompt", text = "Write made.lua" })`);
  const preview = () =>
    ui.exec_lua<number>(`
      local buf = vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)
      return vim.b[buf].anvim_preview and vim.api.nvim_buf_line_count(buf) or 0
    `);
  await ui.waitFor(async () => (await preview()) > 0);
  const mark = ui.mark();
  ui.exec_lua(`vim.schedule(function() error("probe") end)`);
  await Bun.sleep(1000);
  const mode = await ui.request<{ mode: string; blocking: boolean }>("nvim_get_mode");
  expect(mode).toEqual({ mode: "i", blocking: false });
  // The preview goes on growing on the screen.
  expect(new Set(ui.frames(mark).map((f) => f.lines.join("\n"))).size).toBeGreaterThan(5);
  await anvim.type(" y");
  await ui.drain();
  const text = await ui.exec_lua<string[]>(`return vim.api.nvim_buf_get_lines(require("anvim.input").buf(), 0, -1, false)`);
  expect(text).toEqual(["x y"]);
  await ui.waitFor("probe");
});
