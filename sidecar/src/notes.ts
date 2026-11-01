// The project's private notes in .anvim/, which git excludes: a README with
// the standing context, a diary with a file per day, internal reference docs
// and scratch files. The todo list lives there too (todos.ts).
import type {
  HookCallback,
  HookJSONOutput,
  Options,
  PreToolUseHookInput,
  SessionStartHookInput,
} from "@anthropic-ai/claude-agent-sdk";
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { inside, realPath } from "./paths";
import { hookDecision } from "./sandbox";
import { subagentContext } from "./systemprompt";

export const DIR = ".anvim";
const DAY = /^\d{4}-\d{2}-\d{2}\.md$/;
const EXCLUDED = /^\/?\.anvim\/?$/;

export const DIARY_SHAPE = `The diary holds only one markdown file per day, named ${DIR}/diary/YYYY-MM-DD.md. Put scripts, outputs, logs and data in ${DIR}/scratch/, and reference docs in ${DIR}/docs/.`;
export const DIARY_OWNER = "The diary belongs to the main agent. Report what you found, and the main agent records it.";

function readText(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

// Adds .anvim/ to the repo's local exclude file, before anything is written
// there. The exclude file is never shared, unlike .gitignore. A linked
// worktree finds the common one through --git-path.
export async function excludeFromGit(cwd: string): Promise<void> {
  const proc = Bun.spawn(["git", "rev-parse", "--git-path", "info/exclude"], { cwd, stdout: "pipe", stderr: "ignore" });
  const out = (await new Response(proc.stdout).text()).trim();
  if ((await proc.exited) !== 0 || out === "") return;
  const file = resolve(cwd, out);
  const text = readText(file) ?? "";
  if (text.split("\n").some((line) => EXCLUDED.test(line.trim()))) return;
  mkdirSync(dirname(file), { recursive: true });
  const gap = text === "" || text.endsWith("\n") ? "" : "\n";
  appendFileSync(file, `${gap}# anvim's notes and todo list\n${DIR}/\n`);
}

// The local date, as the diary names its files.
export function today(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

// Tells the main agent where today's notes go: with the first prompt, after a
// clear or a compaction, and when the date changes during a session.
export class Notes {
  // The day that Claude last learned.
  private told?: string;

  constructor(
    private cwd: string,
    private day: () => string = () => today(),
  ) {}

  text(day: string): string {
    const days = (() => {
      try {
        return readdirSync(join(this.cwd, DIR, "diary"))
          .filter((name) => DAY.test(name))
          .sort();
      } catch {
        return [];
      }
    })();
    const file = `${DIR}/diary/${day}.md`;
    const lines = [`Today is ${day}.`];
    if (days.includes(`${day}.md`)) lines.push(`Add to today's diary file, ${file}, as you work.`);
    else lines.push(`Today's diary file, ${file}, does not exist yet. Create it when you first have something to record.`);
    const last = days.filter((name) => name < `${day}.md`).at(-1);
    if (last) lines.push(`The newest earlier entry, ${DIR}/diary/${last}, says where the work stopped.`);
    if (existsSync(join(this.cwd, DIR, "README.md"))) {
      lines.push(`${DIR}/README.md holds the standing context. Read it before you work on the project.`);
    } else {
      lines.push(`${DIR}/README.md does not exist yet. Create it when you learn a standing fact about the project.`);
    }
    return lines.join(" ");
  }

  // Claude Code runs an SDK's SessionStart hook only for clear and compact. A
  // compaction can come in the middle of a turn, so it tells at once. After a
  // clear, the next prompt tells.
  sessionStart: HookCallback = async (input) => {
    if ((input as SessionStartHookInput).source !== "compact") {
      this.told = undefined;
      return {};
    }
    this.told = this.day();
    return { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: this.text(this.told) } };
  };

  prompt: HookCallback = async () => {
    const day = this.day();
    if (this.told === day) return {};
    this.told = day;
    return { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: this.text(day) } };
  };

  subagentStart: HookCallback = async () => ({
    hookSpecificOutput: { hookEventName: "SubagentStart", additionalContext: subagentContext() },
  });
}

// An edit in the diary that is not a day file goes back to Claude, as does a
// subagent's edit there.
export function diaryRefusal(cwd: string, input: PreToolUseHookInput): HookJSONOutput | undefined {
  const tool = (input.tool_input ?? {}) as Record<string, unknown>;
  const path = tool.file_path ?? tool.notebook_path;
  if (typeof path !== "string") return undefined;
  const target = resolve(cwd, path);
  // The path as Claude wrote it, and with its symlinks resolved.
  const forms: [file: string, diary: string][] = [
    [target, join(cwd, DIR, "diary")],
    [realPath(target), join(realPath(cwd), DIR, "diary")],
  ];
  for (const [file, diary] of forms) {
    if (!inside(file, diary)) continue;
    if (input.agent_id) return hookDecision("deny", DIARY_OWNER);
    return dirname(file) === diary && DAY.test(basename(file)) ? undefined : hookDecision("deny", DIARY_SHAPE);
  }
  return undefined;
}

// An amnesia session reads no memories and no notes. Off, auto memory also
// keeps the subagents' memory out. The Read deny rule stops the Read tool and
// the Bash commands that name the notes' dir. The sandbox stops the other Bash
// commands, such as a grep over the project.
export function amnesiaOptions(cwd: string, sandbox: Options["sandbox"]): Pick<Options, "sandbox" | "settings"> {
  const dirs = [...new Set([join(cwd, DIR), join(realPath(cwd), DIR)])];
  return {
    sandbox: sandbox?.enabled
      ? { ...sandbox, filesystem: { ...sandbox.filesystem, denyRead: [...(sandbox.filesystem?.denyRead ?? []), ...dirs] } }
      : sandbox,
    settings: {
      autoMemoryEnabled: false,
      autoDreamEnabled: false,
      permissions: { deny: dirs.map((dir) => `Read(/${dir}/**)`) },
    },
  };
}
