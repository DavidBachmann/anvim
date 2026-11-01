import { describe, expect, test } from "bun:test";
import type { HookCallback, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { preToolUse } from "./hooks";
import { amnesiaOptions, DIARY_OWNER, DIARY_SHAPE, diaryRefusal, excludeFromGit, Notes } from "./notes";
import { hookDecision } from "./sandbox";

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "anvim-notes-")));
const signal = new AbortController().signal;

describe("the .anvim folder", () => {
  test("joins the repo's exclude file once, also from a subdir, and skips a dir outside git", async () => {
    const repo = temp();
    Bun.spawnSync(["git", "init", "-q"], { cwd: repo });
    const exclude = join(repo, ".git", "info", "exclude");
    writeFileSync(exclude, "# git's own lines\n*.log");
    mkdirSync(join(repo, "app"));
    await excludeFromGit(join(repo, "app"));
    await excludeFromGit(repo);
    expect(readFileSync(exclude, "utf8")).toBe("# git's own lines\n*.log\n# anvim's notes and todo list\n.anvim/\n");
    mkdirSync(join(repo, ".anvim"));
    writeFileSync(join(repo, ".anvim", "todos.json"), "{}");
    const status = Bun.spawnSync(["git", "status", "--porcelain", "--ignored=no"], { cwd: repo });
    expect(status.stdout.toString()).not.toContain(".anvim");
    const plain = temp();
    await excludeFromGit(plain);
  });

  test("lets only the main agent's day files into the diary, before any preview", async () => {
    const cwd = temp();
    const call = (file_path: string, agent_id?: string) =>
      ({ hook_event_name: "PreToolUse", tool_name: "Write", tool_input: { file_path }, agent_id }) as PreToolUseHookInput;
    const deny = (reason: string) => hookDecision("deny", reason);
    expect(diaryRefusal(cwd, call(join(cwd, ".anvim/diary/2026-11-01.md")))).toBeUndefined();
    expect(diaryRefusal(cwd, call(".anvim/diary/2026-11-01.md"))).toBeUndefined();
    expect(diaryRefusal(cwd, call(".anvim/scratch/debug.mjs"))).toBeUndefined();
    expect(diaryRefusal(cwd, call("src/app.ts"))).toBeUndefined();
    expect(diaryRefusal(cwd, call(".anvim/diary/scripts/debug-script.mjs"))).toEqual(deny(DIARY_SHAPE));
    expect(diaryRefusal(cwd, call(".anvim/diary/26_11_01_topic.md"))).toEqual(deny(DIARY_SHAPE));
    expect(diaryRefusal(cwd, call(".anvim/diary/2026-11-01.md", "agent-1"))).toEqual(deny(DIARY_OWNER));
    let previews = 0;
    const preview: HookCallback = async () => {
      previews++;
      return {};
    };
    const [edit] = preToolUse(preview, undefined, (input) => diaryRefusal(cwd, input));
    const script = call(".anvim/diary/debug.mjs");
    expect(await edit!.hooks[0]!(script, "toolu_1", { signal })).toEqual(deny(DIARY_SHAPE));
    expect(previews).toBe(0);
  });

  test("tells today's diary file once a day, after a clear and at a compaction", async () => {
    const cwd = temp();
    let day = "2026-11-01";
    const notes = new Notes(cwd, () => day);
    const prompt = async () => (await notes.prompt({} as never, undefined, { signal })) as any;
    const first = await prompt();
    expect(first.hookSpecificOutput.additionalContext).toBe(
      "Today is 2026-11-01. Today's diary file, .anvim/diary/2026-11-01.md, does not exist yet. Create it when you first have something to record. .anvim/README.md does not exist yet. Create it when you learn a standing fact about the project.",
    );
    expect(await prompt()).toEqual({});
    mkdirSync(join(cwd, ".anvim", "diary"), { recursive: true });
    for (const name of ["2026-10-30.md", "2026-11-02.md", "notes.md"]) writeFileSync(join(cwd, ".anvim", "diary", name), "");
    writeFileSync(join(cwd, ".anvim", "README.md"), "");
    day = "2026-11-02";
    expect((await prompt()).hookSpecificOutput.additionalContext).toBe(
      "Today is 2026-11-02. Add to today's diary file, .anvim/diary/2026-11-02.md, as you work. The newest earlier entry, .anvim/diary/2026-10-30.md, says where the work stopped. .anvim/README.md holds the standing context. Read it before you work on the project.",
    );
    expect(await notes.sessionStart({ source: "clear" } as never, undefined, { signal })).toEqual({});
    expect((await prompt()).hookSpecificOutput.hookEventName).toBe("UserPromptSubmit");
    const compact = (await notes.sessionStart({ source: "compact" } as never, undefined, { signal })) as any;
    expect(compact.hookSpecificOutput.hookEventName).toBe("SessionStart");
    expect(await prompt()).toEqual({});
  });

  test("an amnesia session reads no memories and cannot read the notes", () => {
    const sandbox = { enabled: true, filesystem: { allowWrite: ["/repo"] } };
    expect(amnesiaOptions("/repo", sandbox)).toEqual({
      sandbox: { enabled: true, filesystem: { allowWrite: ["/repo"], denyRead: ["/repo/.anvim"] } },
      settings: {
        autoMemoryEnabled: false,
        autoDreamEnabled: false,
        permissions: { deny: ["Read(//repo/.anvim/**)"] },
      },
    });
    expect(amnesiaOptions("/repo", { enabled: false }).sandbox).toEqual({ enabled: false });
  });
});
