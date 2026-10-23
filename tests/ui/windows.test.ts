import { afterEach, expect, test } from "bun:test";
import { type Anvim, cursorIn, inBox, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

test("<C-l> and <C-w>l from the code window reach the prompt in normal mode, and no frame shows the cursor in the transcript", async () => {
  anvim = await start();
  const { ui } = anvim;
  for (const key of ["<C-l>", "<C-w>l"]) {
    // H puts the cursor next to the transcript, G next to the prompt.
    for (const motion of ["H", "M", "L", "gg", "G"]) {
      await anvim.toCode();
      const transcript = await anvim.box("transcript");
      const input = await anvim.box("input");
      const mark = ui.mark();
      await ui.input(motion + key);
      await anvim.waitWhere("input", "n");
      await ui.waitFor(() => inBox(ui.cursor, input) && ui.mode === "normal");
      expect(cursorIn(ui.frames(mark), transcript), motion + key).toEqual([]);
    }
  }
});

test("anvim starts in the prompt in normal mode, the first keys can move, and only i types", async () => {
  anvim = await start();
  const { ui } = anvim;
  // The explorer and the sidecar finish starting after this. They must not
  // start insert mode.
  await Bun.sleep(1000);
  expect(await anvim.where()).toEqual({ win: "input", mode: "n" });
  expect(ui.frames().filter((f) => f.mode === "insert").length).toBe(0);
  await ui.input("<C-h>");
  await anvim.waitWhere("code", "n");
  await ui.input("<C-l>");
  await anvim.waitWhere("input", "n");
  await ui.input("<C-h>i");
  await anvim.waitWhere("input", "i");
});
