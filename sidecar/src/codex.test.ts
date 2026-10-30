import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CodexRunner,
  type CodexSettings,
  codexArgs,
  codexModels,
  codexState,
  codexWarning,
  runSettings,
} from "./codex";

describe("codexState", () => {
  test("offers the codex tool only when it is wanted, installed and logged in", async () => {
    const which = (bin: string | null) => () => bin;
    const login = (ok: boolean) => async () => ok;
    expect(await codexState(false, which("/bin/codex"), login(true))).toEqual({ state: "off" });
    expect(await codexState(true, which(null), login(true))).toEqual({ state: "missing" });
    expect(await codexState(true, which("/bin/codex"), login(false))).toEqual({ state: "logged_out" });
    const none = async () => undefined;
    expect(await codexState(true, which("/bin/codex"), login(true), none)).toEqual({ state: "on", bin: "/bin/codex" });
    const terra = [{ slug: "gpt-6.1-terra", name: "GPT-6.1 Terra", hidden: false, efforts: ["low"] }];
    expect(await codexState(true, which("/bin/codex"), login(false), async () => terra)).toEqual({
      state: "logged_out",
    });
    expect(codexWarning("missing")).toContain("--codex");
    expect(codexWarning("logged_out")).toContain("codex login");
    expect(codexWarning("off")).toBeUndefined();
    expect(codexWarning("on", terra)).toBeUndefined();
    expect(codexWarning("on")).toContain("model list");
  });
});

describe("codexModels", () => {
  function stub(body: string): { bin: string; done: () => void } {
    const dir = mkdtempSync(join(tmpdir(), "anvim-codex-"));
    const bin = join(dir, "codex");
    writeFileSync(bin, `#!/bin/sh\n${body}\n`);
    chmodSync(bin, 0o755);
    return { bin, done: () => rmSync(dir, { recursive: true }) };
  }

  test("reads the model list from codex app-server, page by page", async () => {
    // As codex app-server answered, with fewer fields.
    const page1 = {
      id: 1,
      result: {
        data: [
          {
            id: "gpt-6.1-terra",
            model: "gpt-6.1-terra",
            displayName: "GPT-6.1 Terra",
            hidden: false,
            isDefault: true,
            defaultReasoningEffort: "low",
            supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "xhigh" }],
          },
        ],
        nextCursor: "p2",
      },
    };
    const page2 = {
      id: 2,
      result: { data: [{ id: "gpt-old", model: "gpt-old", displayName: "GPT Old", hidden: true }], nextCursor: null },
    };
    const { bin, done } = stub(
      [
        `[ "$1" = app-server ] || exit 2`,
        `read line; case "$line" in *'"method":"initialize","id":0'*) ;; *) exit 3;; esac`,
        `printf '%s\\n' '{"method":"configWarning"}' '{"id":0,"result":{"userAgent":"codex"}}'`,
        `read line; case "$line" in *'"method":"initialized"'*) ;; *) exit 4;; esac`,
        `read line; case "$line" in *'"includeHidden":true'*) ;; *) exit 5;; esac`,
        `printf '%s\\n' '${JSON.stringify(page1)}'`,
        `read line; case "$line" in *'"cursor":"p2"'*) ;; *) exit 6;; esac`,
        `printf '%s\\n' '${JSON.stringify(page2)}'`,
        "while read line; do :; done",
      ].join("\n"),
    );
    expect(await codexModels(bin)).toEqual([
      { slug: "gpt-6.1-terra", name: "GPT-6.1 Terra", hidden: false, efforts: ["low", "xhigh"] },
      { slug: "gpt-old", name: "GPT Old", hidden: true, efforts: [] },
    ]);
    done();
  });

  test("gives undefined when codex exits, answers with an error or never answers", async () => {
    const exits = stub("exit 1");
    const error = stub(`read line; printf '%s\\n' '{"id":0,"error":{"code":-32600,"message":"no"}}'; cat >/dev/null`);
    const silent = stub("while read line; do :; done");
    const started = Date.now();
    expect(await codexModels(exits.bin, 500)).toBeUndefined();
    expect(await codexModels(error.bin, 500)).toBeUndefined();
    expect(await codexModels(silent.bin, 300)).toBeUndefined();
    expect(await codexModels("/nonexistent/codex", 300)).toBeUndefined();
    expect(Date.now() - started).toBeLessThan(2000);
    for (const s of [exits, error, silent]) s.done();
  });
});

describe("codexArgs", () => {
  test("takes the call's model and effort over anvim's defaults, and passes no flag without either", () => {
    const task = { description: "Review", prompt: "Review a.ts" };
    const defaults = { model: "gpt-5.1-codex-mini", effort: "low" };
    const args = (input: Parameters<typeof runSettings>[0], d: CodexSettings = defaults) =>
      codexArgs("/bin/codex", "/work", input.read_only === true, runSettings(input, d, {}));
    const head = ["/bin/codex", "exec", "--json", "-C", "/work"];
    const tail = ["--skip-git-repo-check", "-"];
    expect(args({ ...task, model: "o3", effort: "high", read_only: true })).toEqual([
      ...head,
      ...["-s", "read-only", "-m", "o3", "-c", 'model_reasoning_effort="high"'],
      ...tail,
    ]);
    expect(args({ ...task, effort: "xhigh" })).toEqual([
      ...head,
      ...["-s", "workspace-write", "-m", "gpt-5.1-codex-mini", "-c", 'model_reasoning_effort="xhigh"'],
      ...tail,
    ]);
    expect(args(task, {})).toEqual([...head, "-s", "workspace-write", ...tail]);
  });

  test("hands an MCP server to the run with -c values that parse as TOML", () => {
    const server = {
      name: "claude-in-chrome",
      command: '/Users/a b/"x"\\claude',
      args: ["--claude-in-chrome-mcp"],
      env: { CLAUDE_CONFIG_DIR: "/Users/a/.claude-é", CLAUDE_CHROME_PERMISSION_MODE: "ask" },
    };
    const args = codexArgs("/bin/codex", "/work", true, {}, [server]);
    expect(args.slice(-2)).toEqual(["--skip-git-repo-check", "-"]);
    const config: Record<string, unknown> = {};
    args.forEach((arg, i) => {
      if (args[i - 1] !== "-c") return;
      const at = arg.indexOf("=");
      const key = arg.slice(0, at);
      expect(key.startsWith("mcp_servers.claude-in-chrome.")).toBe(true);
      config[key.split(".").at(-1)!] = (Bun.TOML.parse(`v = ${arg.slice(at + 1)}`) as { v: unknown }).v;
    });
    expect(config).toEqual({
      command: server.command,
      args: server.args,
      env: server.env,
      default_tools_approval_mode: "approve",
    });
  });
});

describe("CodexRunner", () => {
  test("turns off cmux's Codex hooks for the run", async () => {
    const dir = mkdtempSync(join(tmpdir(), "anvim-codex-"));
    const bin = join(dir, "codex");
    writeFileSync(bin, `#!/bin/sh\nprintf %s "$CMUX_CODEX_HOOKS_DISABLED" > "${dir}/env"\ncat >/dev/null\n`);
    chmodSync(bin, 0o755);
    const notes: string[] = [];
    const codex = new CodexRunner({
      bin,
      cwd: dir,
      emit: () => {},
      notify: (text) => notes.push(text),
      defaults: () => ({}),
      config: () => ({}),
    });
    codex.start({ description: "Review", prompt: "Review a.ts" }, undefined);
    while (notes.length === 0) await Bun.sleep(5);
    expect(readFileSync(join(dir, "env"), "utf8")).toBe("1");
    rmSync(dir, { recursive: true });
  });
});
