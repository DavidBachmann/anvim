// snacks' pickers jump into the code window, also while it shows the preview
// of a new file, which is no file buffer.
import { afterEach, expect, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const CONTENT = "local made = 1\nlocal more = 2\nreturn made + more\n";

const field = (key: string, phase: string, x?: string) =>
  anvim!.ui.exec_lua(
    `
    local key, phase, x = ...
    require("anvim.sidecar").dispatch({ type = "tool_field", id = "w1", name = "Write", key = key, phase = phase,
      text = phase == "delta" and x or nil, value = phase == "end" and x or nil })
  `,
    key,
    phase,
    x ?? null,
  );

// The name of the code window's buffer, or the path that its Write preview writes.
const shown = () =>
  anvim!.ui.exec_lua<string>(`
    local buf = vim.api.nvim_win_get_buf(require("anvim.layout").wins.code)
    return vim.b[buf].anvim_preview and "preview:" .. vim.b[buf].anvim_preview or vim.api.nvim_buf_get_name(buf)
  `);

const errors = () =>
  anvim!.ui.exec_lua<{ errmsg: string; notes: string[] }>(`
    local notes = {}
    for _, n in ipairs(Snacks.notifier.get_history()) do
      if n.level == "error" or n.level == "warn" then
        notes[#notes + 1] = n.msg
      end
    end
    return { errmsg = vim.v.errmsg, notes = notes }
  `);

// Claude starts to write a new file, and the code window follows it. The
// preview waits for more input, as it does while Claude generates.
async function startWrite(path: string) {
  const { ui } = anvim!;
  // snacks ranks windows by when their buffer was last current, in whole
  // seconds, and a picker that finds no file window takes the last split.
  // After a second, that is often the transcript.
  await Bun.sleep(1100);
  await anvim!.capture();
  await ui.exec_lua(`
    vim.v.errmsg = ""
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "turn_start" })
    sidecar.dispatch({ type = "tool_start", id = "w1", name = "Write" })
  `);
  await field("file_path", "end", path);
  await field("content", "start");
  await field("content", "delta", "local made = 1\n");
  await ui.waitFor(async () => (await shown()) === "preview:" + path);
  await ui.waitFor("local made = 1");
}

// The rest of the input comes, the preview catches up, and Claude Code writes
// the file once the plugin answers.
async function finishWrite(path: string) {
  const { ui } = anvim!;
  await field("content", "delta", "local more = 2\nreturn made + more\n");
  await field("content", "end", CONTENT);
  await ui.exec_lua(`
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "tool_input_end", id = "w1" })
    sidecar.dispatch({ type = "await_preview", req = 1, tool_use_id = "w1" })
  `);
  await ui.waitFor(() =>
    ui.exec_lua<boolean>(`
      for _, msg in ipairs(_G.anvim_sent) do
        if msg.type == "preview_done" and msg.req == 1 then
          return true
        end
      end
      return false
    `),
  );
  expect(existsSync(path)).toBe(false);
  writeFileSync(path, CONTENT);
  await ui.exec_lua(`
    require("anvim.sidecar").dispatch({ type = "tool_result", id = "w1", is_error = false, text = "ok",
      result = { type = "create" } })
  `);
  const previews = await ui.exec_lua<number>(`
    return #vim.tbl_filter(function(buf)
      return vim.b[buf].anvim_preview ~= nil
    end, vim.api.nvim_list_bufs())
  `);
  expect(previews).toBe(0);
}

// Back in the prompt, the code window catches up to the written file.
async function catchUp(path: string) {
  const { ui } = anvim!;
  await ui.input("<C-w>l");
  await anvim!.waitWhere("input", "n");
  await ui.waitFor(async () => (await shown()) === path);
  await ui.waitFor("return made + more");
}

test("enter in the explorer opens a file in the code window while Claude writes a new file", async () => {
  anvim = await start();
  const { ui } = anvim;
  const path = join(anvim.dir, "made_new.lua");
  const other = join(anvim.dir, "matchparen.lua");
  await startWrite(path);

  // <leader>e closes the explorer, and opens it again with the cursor in its list.
  await ui.input(" e");
  await ui.waitFor(() => ui.exec_lua<boolean>(`return require("anvim.tree").explorer() == nil`));
  await ui.input(" e");
  await anvim.waitWhere("snacks_picker_list", "n");
  await ui.exec_lua(
    `
    local file = ...
    local list = require("anvim.tree").explorer().list
    for i = 1, list:count() do
      if list:get(i).file == file then
        list:view(i)
      end
    end
  `,
    other,
  );
  await ui.input("<CR>");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(async () => (await shown()) === other);
  await ui.waitFor("local api = vim.api");
  expect(await errors()).toEqual({ errmsg: "", notes: [] });

  // The preview goes on in its hidden buffer, and the file arrives.
  await finishWrite(path);
  expect(await shown()).toBe(other);
  await catchUp(path);
  expect(await errors()).toEqual({ errmsg: "", notes: [] });
});

test("the file picker opens a file in the code window while Claude writes a new file", async () => {
  anvim = await start();
  const { ui } = anvim;
  const path = join(anvim.dir, "made_new.lua");
  const other = join(anvim.dir, "matchparen.lua");
  await startWrite(path);

  await ui.input("  ");
  await anvim.waitWhere("snacks_picker_input", "i");
  await anvim.type("matchparen");
  await ui.waitFor(() =>
    ui.exec_lua<boolean>(`
      local picker = Snacks.picker.get({ source = "files" })[1]
      local item = picker and picker:current()
      return item ~= nil and item.file == "matchparen.lua"
    `),
  );
  await ui.input("<CR>");
  await anvim.waitWhere("code", "n");
  await ui.waitFor(async () => (await shown()) === other);
  await ui.waitFor("local api = vim.api");
  expect(await errors()).toEqual({ errmsg: "", notes: [] });

  await finishWrite(path);
  expect(await shown()).toBe(other);
  await catchUp(path);
  expect(await errors()).toEqual({ errmsg: "", notes: [] });
});
