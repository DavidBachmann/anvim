// A focused subagent: the code window follows its reads only, and the
// statusline, the footer and its Agent line show the focus in its color.
import { afterEach, expect, test } from "bun:test";
import { type Anvim, type Box, cells, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

const files = Object.fromEntries(
  ["alpha", "beta", "gamma", "delta"].map((name) => [
    `${name}.js`,
    Array.from({ length: 6 }, (_, i) => `const ${name}${i + 1} = ${i + 1};`).join("\n") + "\n",
  ]),
);

// What the code window shows: the file whose lines are in it, if any.
const shown = (lines: string[], box: Box) => {
  const text = lines.slice(box.row, box.row + box.height).map((line) => cells(line, box.col, box.width));
  return Object.keys(files)
    .map((file) => file.replace(".js", ""))
    .filter((name) => text.some((line) => line.includes(`const ${name}1 `)));
};

// A tool call of agent `id`, or of the main agent for null, as the sidecar sends it.
const read = (id: string | null, file: string, offset?: number) =>
  anvim!.ui.exec_lua(
    `
    local id, file, offset = ...
    require("anvim.sidecar").dispatch({
      type = "tool_use", id = "read_" .. file .. tostring(id), name = "Read",
      input = { file_path = vim.fn.getcwd() .. "/" .. file, offset = offset ~= vim.NIL and offset or nil },
      parent_id = id ~= vim.NIL and "tu_" .. id or nil, agent_id = id ~= vim.NIL and id or nil,
    })
  `,
    id,
    file,
    offset ?? null,
  );

test("the code window follows the focused agent only, and no frame shows another agent's file", async () => {
  anvim = await start({ files });
  const { ui } = anvim;
  await ui.exec_lua(`
    local sidecar = require("anvim.sidecar")
    sidecar.dispatch({ type = "turn_start" })
    for _, id in ipairs({ "a1", "a2" }) do
      local input = { description = "Read " .. id, subagent_type = "Explore" }
      sidecar.dispatch({ type = "tool_start", id = "tu_" .. id, name = "Agent" })
      sidecar.dispatch({ type = "tool_use", id = "tu_" .. id, name = "Agent", input = input })
      sidecar.dispatch({ type = "agent_start", agent_id = id, tool_use_id = "tu_" .. id, description = input.description,
        subagent_type = "Explore", depth = 1, background = false })
    end
  `);
  const box = await anvim.box("code");
  const mark = ui.mark();
  await read("a2", "beta.js", 3);
  await Bun.sleep(50);
  expect(shown(ui.lines(), box)).toEqual([]);
  // In the prompt, in normal mode: <leader>c2.
  await ui.input(" c2");
  await ui.waitFor(() => shown(ui.lines(), box).includes("beta"));
  for (const [id, file] of [
    ["a1", "alpha.js"],
    [null, "gamma.js"],
    ["a2", "delta.js"],
  ] as const) {
    await read(id, file);
    await ui.drain();
    await Bun.sleep(50);
  }
  await ui.waitFor(() => shown(ui.lines(), box).includes("delta"));
  // Each frame shows nothing, then beta, then delta, with no file between.
  const seen: string[] = [];
  for (const f of ui.frames(mark)) {
    const now = shown(f.lines, box).join(",");
    if (now !== "" && now !== seen.at(-1)) seen.push(now);
  }
  expect(seen).toEqual(["beta", "delta"]);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });

  // The footer names the agent in its color, and so do its ◉ and the end of
  // the agent's Agent line. The statusline leaves it out.
  const want = await ui.exec_lua<number>(`return vim.api.nvim_get_hl(0, { name = "AnvimAgent2", link = false }).fg`);
  const fg = (row: number, col: number) => ui.attrs.get(ui.grid[row]![col]!.hl)?.rgb.foreground;
  const find = (text: string) => {
    const lines = ui.lines();
    const row = lines.findIndex((line) => line.includes(text));
    expect(row).toBeGreaterThan(-1);
    return { row, col: [...lines[row]!.slice(0, lines[row]!.indexOf(text))].length };
  };
  const input = await anvim.box("input");
  const footer = await anvim.footer();
  const at = footer.search(/◉ (following )?Explore 2/);
  expect(at).toBeGreaterThan(-1);
  expect(fg(input.row + input.height - 1, input.col + [...footer.slice(0, at)].length)).toBe(want);
  expect(ui.lines().at(-1)).not.toContain("Explore 2");
  const line = find("⏺ Explore(Read a2)");
  expect(ui.lines()[line.row]).toContain("◉ focused");
  const focused = find("◉ focused");
  expect(fg(focused.row, focused.col)).toBe(want);
  const dot = find("⏺◉");
  expect(fg(dot.row, dot.col + 1)).toBe(want);
});
