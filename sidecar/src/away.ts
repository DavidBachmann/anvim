// Away mode and held calls. Only the main agent asks the user, and only
// while the user is present. A call that would ask otherwise is held: anvim
// denies it with a text for Claude and lists it for the user. While away,
// AskUserQuestion gets a text that tells Claude to answer itself. A plan's
// approval always waits for the user.
import type { HookCallback, HookJSONOutput, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import { REASONS } from "./sandbox";

const OUTSIDE = REASONS.outside("");

export const AWAY_ON =
  "The user is away now. Until they return, anvim answers each request for them: it holds calls that would ask and lists them for the user, and you choose the answers to your own questions. When the next step is clear, take it instead of ending your turn with a question.";
export const AWAY_OFF = "The user is back. Requests ask them again.";
export const QUESTION =
  "The user is away, so anvim did not show this question. Choose the option that you would recommend, tell the user which one you chose and why, and go on. anvim lists the question for the user's return.";

// The reasons of held requests that no guard asked about.
export const ASKS = "would ask the user";
export const ASKS_QUESTION = "a question";

// What Claude reads in place of a held call's result. It never says "try
// another way", because Claude could then make a held edit with a Bash write.
export function heldText(reason: string, away: boolean, tmpDir = "$TMPDIR"): string {
  const who = away
    ? "The user is away, so anvim did not ask them. It denied this call and put it on a list for their return."
    : "anvim does not ask the user about a subagent's calls. It denied this call and put it on a list for the user.";
  const same = "Do not make the same change another way.";
  let why: string;
  if (reason === REASONS.escape) {
    why =
      "The command would run outside the sandbox. It can run inside the sandbox, where Bash can write in the project and in $TMPDIR, and in the npm, bun and go caches. Point other outputs to $TMPDIR, for example XDG_CACHE_HOME=$TMPDIR/cache.";
  } else if (reason === REASONS.excluded) {
    why = "The settings exclude this command from the sandbox. Another command that runs inside the sandbox is fine.";
  } else if (reason === REASONS.settings) {
    why = `The file holds Claude Code's settings for this project, and they can widen the sandbox. ${same}`;
  } else if (reason === REASONS.config) {
    why = `The file configures tools that run outside the sandbox, such as git hooks or shell startup files. ${same}`;
  } else if (reason.startsWith(OUTSIDE)) {
    why = `The file is outside the project and the dirs that anvim trusts. ${same} Scratch files can go in the project or in ${tmpDir}.`;
  } else if (reason === REASONS.codex) {
    why = `A Codex run that writes files works outside the sandbox. A read-only run needs no answer. ${same}`;
  } else {
    why = "Do not get the same result another way.";
  }
  const end = away
    ? "Go on with the rest of the task, and name this call in your report."
    : "Go on with the rest of the task, and name this call in your report. The main agent can ask the user.";
  return `${who} ${why} ${end}`;
}

// What a held request targets: the command, the path, the URL, the questions.
// An unknown tool shows its input, so two different calls never group as one.
export function heldTarget(tool: string, input: Record<string, unknown>): string {
  const { command, file_path, notebook_path, url, query, host, prompt } = input;
  if (tool === "AskUserQuestion" && Array.isArray(input.questions)) {
    return input.questions
      .map((q) => (q && typeof q === "object" ? (q as { question?: unknown }).question : undefined))
      .filter((q): q is string => typeof q === "string")
      .join(" / ");
  }
  const text = [command, file_path, notebook_path, url, query, host, prompt].find((v) => typeof v === "string");
  if (typeof text === "string") return text;
  const json = JSON.stringify(input);
  return json === "{}" ? "" : json.slice(0, 300);
}

// The main agent hears each switch once, with its next tool call or prompt.
// A switch back before then tells nothing, because nothing changed for it.
export class AwayNotice {
  // The state that the main agent knows.
  private told = false;

  constructor(private away: () => boolean) {}

  private next(hookEventName: "PreToolUse" | "UserPromptSubmit"): HookJSONOutput {
    const on = this.away();
    if (on === this.told) return {};
    this.told = on;
    return { hookSpecificOutput: { hookEventName, additionalContext: on ? AWAY_ON : AWAY_OFF } };
  }

  preToolUse: HookCallback = async (input) =>
    (input as PreToolUseHookInput).agent_id ? {} : this.next("PreToolUse");

  prompt: HookCallback = async () => this.next("UserPromptSubmit");

  // /clear starts a conversation that knows nothing of away mode.
  reset(): void {
    this.told = false;
  }
}
