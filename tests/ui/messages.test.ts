// Neovim's own command line shows the messages. Language servers report their
// progress, and nothing shows it. anvim's notices and multi-line notifications
// go to snacks' notifier, and ask for no Enter.
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
  await ui.waitFor(() => status().includes("recording @q"), 250);
  await ui.input("q");
  await ui.waitFor(() => !status().includes("recording"), 250);
});
