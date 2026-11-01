// The PreToolUse hooks: the preview handshake, the todo tools' refusal, the
// diary's shape, and the sandbox's guards while the sandbox is on.
import type {
  HookCallback,
  HookCallbackMatcher,
  HookJSONOutput,
  PreToolUseHookInput,
} from "@anthropic-ai/claude-agent-sdk";
import { hookDecision, type SandboxGuard } from "./sandbox";
import { CODEX_TOOL, TODO_TOOLS } from "./tools";

// A guard's own prompt in bypass mode waits for the user. When a hook misses
// its timeout, in seconds, Claude Code does not run the tool, and Claude
// reads that as an error.
export const GUARD_TIMEOUT_S = 24 * 60 * 60;

export const TODO_REFUSAL =
  "The todo list belongs to the main agent. Do your task and report back. The main agent updates the list.";

// A subagent gets a task and delivers it. The main agent marks the item done
// once it has checked the work. A deny holds in every mode.
export const refuseSubagentTodos: HookCallback = async (input) =>
  input.agent_id ? hookDecision("deny", TODO_REFUSAL) : {};

// The edit hooks run in one callback, because Claude Code runs the hooks of a
// matcher in parallel. The diary check comes first, so a refused edit gets no
// preview. The edit guard comes last, so its prompt opens once the preview has
// caught up.
export function preToolUse(
  preview: HookCallback,
  guard?: SandboxGuard,
  diary?: (input: PreToolUseHookInput) => HookJSONOutput | undefined,
): HookCallbackMatcher[] {
  const todos = { matcher: TODO_TOOLS.join("|"), hooks: [refuseSubagentTodos] };
  const edit: HookCallback = async (input, toolUseID, opts) => {
    const refusal = diary?.(input as PreToolUseHookInput);
    if (refusal) return refusal;
    const shown = await preview(input, toolUseID, opts);
    return guard ? guard.edit(input, toolUseID, opts) : shown;
  };
  if (!guard) return [{ matcher: "Edit|Write|NotebookEdit", hooks: [edit] }, todos];
  return [
    { matcher: "Edit|Write|NotebookEdit", hooks: [edit], timeout: GUARD_TIMEOUT_S },
    { matcher: "Bash", hooks: [guard.bash], timeout: GUARD_TIMEOUT_S },
    { matcher: CODEX_TOOL, hooks: [guard.codex], timeout: GUARD_TIMEOUT_S },
    todos,
  ];
}
