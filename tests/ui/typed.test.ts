// A focused subagent's edit arrives whole. anvim types it into the code
// window at a steady pace, and the file changes only after that.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { type Anvim, type Box, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const OLD = Array.from({ length: 6 }, (_, i) => `const alpha${i + 1} = ${i + 1};`);
const NEW = [
  "// alpha3 was the third value.",
  "// The agent makes it ten times larger,",
  "// and it keeps its name.",
  "const alpha3 = 30;",
];

// The code window's rows, without the gutter on their left.
const codeRows = (lines: string[], box: Box) => {
  const rows = lines.slice(box.row, box.row + box.height).map((l) => [...l].slice(box.col, box.col + box.width).join(""));
  const first = rows.find((r) => r.includes("const alpha1 ")) ?? "";
  const gutter = [...first.slice(0, first.indexOf("const alpha1 "))].length;
  return rows.map((r) => [...r].slice(gutter).join("").trimEnd());
};

// The new text that a frame shows under the old line, without the cursor.
// LazyVim's 'listchars' show a space before the cursor as a trailing "-".
const typed = (lines: string[], box: Box) => {
  const rows = codeRows(lines, box);
  const at = rows.indexOf(OLD[2]!);
  const end = rows.indexOf(OLD[3]!);
  return at >= 0 && end > at ? rows.slice(at + 1, end).join("\n").replace(/-?▍/, "") : null;
};

test("the focused agent's edit grows over several frames, struck through, before the file changes", async () => {
  anvim = await start({ files: { "alpha.js": OLD.join("\n") + "\n" } });
  const { ui } = anvim;
  const path = join(anvim.dir, "alpha.js");
  const edit = { file_path: path, old_string: OLD[2], new_string: NEW.join("\n") };
  // Plays Claude Code's part: the hook holds the edit until preview_done, and
  // the file changes about 10 ms after it.
  await ui.exec_lua(
    `
    local path, edit, after = ...
    local sidecar = require("anvim.sidecar")
    _G.at_done = nil
    sidecar.send = function(msg)
      if msg.type == "preview_done" and msg.req == 1 then
        _G.at_done = {
          buf = vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false),
          disk = vim.fn.readfile(path),
        }
        vim.defer_fn(function()
          vim.fn.writefile(after, path)
          sidecar.dispatch({ type = "tool_result", id = "te1", is_error = false, text = "ok", parent_id = "tu_a1", agent_id = "a1" })
        end, 10)
      end
    end
    sidecar.dispatch({ type = "turn_start" })
    local input = { description = "Edit alpha", subagent_type = "general-purpose" }
    sidecar.dispatch({ type = "tool_start", id = "tu_a1", name = "Agent" })
    sidecar.dispatch({ type = "tool_use", id = "tu_a1", name = "Agent", input = input })
    sidecar.dispatch({ type = "agent_start", agent_id = "a1", tool_use_id = "tu_a1", description = input.description,
      subagent_type = "general-purpose", depth = 1, background = false })
    require("anvim.follow").set_focus("a1")
  `,
    path,
    edit,
    [...OLD.slice(0, 2), ...NEW, ...OLD.slice(3)],
  );
  const box = await anvim.box("code");
  const mark = ui.mark();
  await ui.exec_lua(
    `
    local edit = ...
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "await_preview", req = 1, tool_use_id = "te1", agent_id = "a1", name = "Edit", input = edit })
    sidecar.dispatch({ type = "tool_use", id = "te1", name = "Edit", input = edit, parent_id = "tu_a1", agent_id = "a1" })
  `,
    edit,
  );

  // Midway, the old line is struck through, and the file on disk is as it was.
  await ui.waitFor(() => (typed(ui.lines(), box) ?? "").includes("ten times"));
  expect(readFileSync(path, "utf8")).toBe(OLD.join("\n") + "\n");
  const lines = ui.lines();
  const row = lines.findIndex((l, r) => r >= box.row && l.includes(OLD[2]!));
  const col = [...lines[row]!.slice(0, lines[row]!.indexOf(OLD[2]!))].length;
  const struck = ui.grid[row]!.slice(col, col + OLD[2]!.length).map((c) => ui.attrs.get(c.hl));
  expect(struck.every((a) => a?.rgb.strikethrough && a.names.includes("AnvimDelete"))).toBe(true);

  // The reload shows the file, with the new lines in place of the old one.
  await ui.waitFor(() => codeRows(ui.lines(), box).includes(NEW[3]!) && typed(ui.lines(), box) === null);
  expect(codeRows(ui.lines(), box).slice(0, 9)).toEqual([...OLD.slice(0, 2), ...NEW, ...OLD.slice(3)]);

  // Each frame shows a longer start of the new text, up to all of it.
  const seen: string[] = [];
  for (const f of ui.frames(mark)) {
    const now = typed(f.lines, box);
    if (now && now !== seen.at(-1)) seen.push(now);
  }
  const all = NEW.join("\n");
  expect(seen.every((s, i) => all.startsWith(s) && (i === 0 || s.length > seen[i - 1]!.length))).toBe(true);
  expect(seen.length).toBeGreaterThanOrEqual(5);
  expect(seen.at(-1)).toBe(all);

  // The answer came once all of it was in, and before the file changed.
  const done = await ui.exec_lua<{ buf: string[]; disk: string[] }>(`return _G.at_done`);
  expect(done.disk).toEqual(OLD);
  expect(done.buf).toEqual([...OLD.slice(0, 3), ...NEW, ...OLD.slice(3)]);
});
