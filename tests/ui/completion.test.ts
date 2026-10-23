// The prompt's completion menu is Neovim's own popup menu, over the transcript.
import { afterEach, expect, test } from "bun:test";
import type { Anvim } from "./helpers.ts";
import { start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

// A blended menu shows the text under each of its blank cells.
test("the / menu hides the transcript under it", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.notices(20, "░".repeat(120));
  // Ten rows, and one long description that leaves blank cells in the others.
  await ui.exec_lua(`
    local commands = {}
    for i = 1, 10 do
      commands[i] = { name = "c" .. i, description = i == 1 and ("w"):rep(40) or "x" }
    end
    require("anvim.completion").commands = commands
  `);
  await anvim.insert();
  await ui.input("/");
  await ui.waitFor(() => ui.exec_lua<boolean>("return vim.fn.pumvisible() == 1"));
  const rows = () => ui.lines().flatMap((line) => line.match(/│.\/c\d+[^│]*│/g) ?? []);
  await ui.waitFor(() => rows().length > 0);
  expect(rows().filter((row) => row.includes("░"))).toEqual([]);
});
