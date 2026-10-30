// The PreToolUse hooks: the preview handshake, the todo tools' refusal, and
// the sandbox's guards while the sandbox is on.
import type { HookCallback, HookCallbackMatcher } from "@anthropic-ai/claude-agent-sdk";
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

// The edit guard runs after the preview hook in one callback, because Claude
// Code runs the hooks of a matcher in parallel. So its prompt opens once the
// preview has caught up.
export function preToolUse(preview: HookCallback, guard?: SandboxGuard): HookCallbackMatcher[] {
  const todos = { matcher: TODO_TOOLS.join("|"), hooks: [refuseSubagentTodos] };
  if (!guard) return [{ matcher: "Edit|Write|NotebookEdit", hooks: [preview] }, todos];
  const edit: HookCallback = async (input, toolUseID, opts) => {
    await preview(input, toolUseID, opts);
    return guard.edit(input, toolUseID, opts);
  };
  return [
    { matcher: "Edit|Write|NotebookEdit", hooks: [edit], timeout: GUARD_TIMEOUT_S },
    { matcher: "Bash", hooks: [guard.bash], timeout: GUARD_TIMEOUT_S },
    { matcher: CODEX_TOOL, hooks: [guard.codex], timeout: GUARD_TIMEOUT_S },
    todos,
  ];
}
