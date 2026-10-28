import { describe, expect, test } from "bun:test";
import type { SessionMessage } from "@anthropic-ai/claude-agent-sdk";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CodexRunner,
  type CodexSettings,
  CodexStream,
  codexArgs,
  codexModels,
  codexSettings,
  codexState,
  codexWarning,
  unwrapShell,
} from "./codex";
import { historyEvents } from "./sessions";

// As codex-cli 0.164.0 printed it for `codex exec --json`. The error item is
// a wrapper's warning, not a failure.
const recording = `
{"type":"thread.started","thread_id":"01a17317-c271-71b0-a36b-379525be2574"}
{"type":"item.completed","item":{"id":"item_0","type":"error","message":"\`--dangerously-bypass-hook-trust\` is enabled."}}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I'll read notes.txt, then change \`b\` to \`B\`.\\n"}}
{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat notes.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat notes.txt'","aggregated_output":"a\\nb\\n","exit_code":0,"status":"completed"}}
{"type":"item.started","item":{"id":"item_4","type":"file_change","changes":[{"path":"/work/notes.txt","kind":"update"}],"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"/work/notes.txt","kind":"update"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"done"}}
{"type":"turn.completed","usage":{"input_tokens":71005,"cached_input_tokens":54144,"cache_write_input_tokens":0,"output_tokens":118,"reasoning_output_tokens":0}}
`;

const agent = { agent_id: "codex-1", parent_id: "toolu_1" };

describe("CodexStream", () => {
  test("turns a Codex run into the events of a subagent", () => {
    const stream = new CodexStream("codex-1", "toolu_1", "/work");
    const events = recording
      .trim()
      .split("\n")
      .flatMap((line) => stream.line(line));
    expect(events).toEqual([
      { type: "agent_text", ...agent, text: "I'll read notes.txt, then change `b` to `B`.\n" },
      { type: "agent_progress", agent_id: "codex-1", description: "Running cat notes.txt", tool_uses: 1, last_tool: "Bash" },
      { type: "tool_use", id: "codex-1:item_3", name: "Bash", input: { command: "cat notes.txt" }, ...agent },
      { type: "tool_result", id: "codex-1:item_3", is_error: false, text: "a\nb\n", ...agent },
      { type: "agent_progress", agent_id: "codex-1", description: "Editing notes.txt", tool_uses: 2, last_tool: "Edit" },
      { type: "tool_use", id: "codex-1:item_4:0", name: "Edit", input: { file_path: "/work/notes.txt" }, ...agent },
      { type: "tool_result", id: "codex-1:item_4:0", is_error: false, text: "Updated notes.txt", ...agent },
      { type: "agent_text", ...agent, text: "done" },
      { type: "agent_context", agent_id: "codex-1", tokens: 71123 },
    ]);
    const end = stream.end({ description: "Change b to B", code: 0, stderr: "", durationMs: 9000 });
    expect(end.event).toEqual({
      type: "agent_end",
      agent_id: "codex-1",
      tool_use_id: "toolu_1",
      status: "completed",
      summary: "done",
      tool_uses: 2,
      tokens: 71123,
      duration_ms: 9000,
    });
    // A resumed session draws the saved notification as the agent's end.
    const saved = {
      type: "user",
      uuid: "u",
      session_id: "s",
      parent_tool_use_id: null,
      message: { role: "user", content: end.notification },
    } as unknown as SessionMessage;
    expect(historyEvents([saved])).toEqual([{ ...end.event, description: "Change b to B" } as typeof end.event]);
  });

  test("a failed run ends with the tail of stderr", () => {
    const stream = new CodexStream("codex-2", "toolu_2", "/work");
    const end = stream.end({ description: "Fix it", code: 1, stderr: "Error: not logged in\n", durationMs: 10 });
    expect(end.event).toMatchObject({ status: "failed", summary: "Codex exited with code 1.\nError: not logged in" });
    expect(end.notification).toContain("<status>failed</status>");
  });

  test("unwraps the shell that Codex runs each command in", () => {
    expect(unwrapShell("/bin/zsh -lc 'cat notes.txt'")).toBe("cat notes.txt");
    expect(unwrapShell(`/bin/bash -lc 'echo '"'"'hi'"'"''`)).toBe("echo 'hi'");
    expect(unwrapShell(`/bin/zsh -lc "grep -n \\"x\\" a.ts"`)).toBe('grep -n "x" a.ts');
    expect(unwrapShell("ls -la")).toBe("ls -la");
  });
});

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
    const args = (input: Parameters<typeof codexSettings>[0], d: CodexSettings = defaults) =>
      codexArgs("/bin/codex", "/work", input.read_only === true, codexSettings(input, d));
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
