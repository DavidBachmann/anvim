// anvim has no command line row, so the statusline shows a macro recording.
import { afterEach, test } from "bun:test";
import { type Anvim, start } from "./helpers.ts";

let anvim: Anvim | undefined;
afterEach(async () => {
  await anvim?.close();
  anvim = undefined;
});

test("the statusline shows a macro recording, as there is no command line row", async () => {
  anvim = await start();
  const { ui } = anvim;
  await anvim.toCode();
  const status = () => ui.lines().at(-1)!;
  await ui.input("qq");
  await ui.waitFor(() => status().includes("recording @q"));
  await ui.input("q");
  await ui.waitFor(() => !status().includes("recording"));
});
