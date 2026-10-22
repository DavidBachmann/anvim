import { expect, test } from "bun:test";
import { join } from "node:path";
import { start } from "./helpers.ts";

const running = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

// The processes whose command line has the text.
const named = (text: string) =>
  Bun.spawnSync(["ps", "-axww", "-o", "pid=,command="])
    .stdout.toString()
    .split("\n")
    .flatMap((line) => (line.includes(text) ? [Number(line.trim().split(/\s+/)[0])] : []));

// Claude's sandbox does not let ps run, and close() needs it to find the server.
const psRuns = (() => {
  try {
    return Bun.spawnSync(["ps", "-o", "pid="]).success;
  } catch {
    return false;
  }
})();

test.skipIf(!psRuns)("close() stops the language server, and leaves other processes that name the XDG dir alone", async () => {
  const anvim = await start();
  const { ui } = anvim;
  // Like a shell or an editor that has the log open. A shell that runs one
  // command would exec it, so give it two.
  const log = join(ui.xdg, "state/anvim/anvim.log");
  const other = Bun.spawn(["sh", "-c", "sleep 30; exit 0", "sh", log]);
  try {
    await anvim.toCode();
    await ui.waitFor(() => ui.exec_lua(`return #vim.lsp.get_clients({ name = "lua_ls", _uninitialized = true }) > 0`));
    const servers = named(`--logpath=${ui.xdg}/`);
    expect(servers.length).toBe(1);
    expect(named(log)).toContain(other.pid);
    await anvim.close();
    expect(servers.filter(running)).toEqual([]);
    expect(running(other.pid)).toBe(true);
  } finally {
    other.kill();
  }
});
