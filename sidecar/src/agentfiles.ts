// Claude Code gives each turn the agents that it started with. Between turns,
// it rereads only the agent folders that existed when the session started. So
// when Claude writes an agent file, anvim reloads the agents, and tells Claude
// that the agent works from the next turn.
import type {
  HookCallback,
  HookCallbackMatcher,
  HookJSONOutput,
  PostToolUseHookInput,
  Query,
} from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { gitRoot, realPath } from "./sandbox";

export const NEXT_TURN =
  "anvim reloaded the agents. Claude Code gives each turn the agents that it started with, so the Agent tool can run this file's agent from the next turn on, not in this turn. If the work needs this agent, end the turn and tell the user that it is ready.";
export const HELD =
  "anvim did not reload the agents, because the reload would also change the session's tools. The Agent tool cannot run this file's agent in this turn. Ask the user to run /reload-plugins, and the turn after that can run it.";

// The folders that Claude Code loads agents from: the project's and the login's.
export function agentFolders(cwd: string, configDir: string): string[] {
  const roots = [cwd, gitRoot(cwd)].filter((root): root is string => root !== undefined);
  return [...roots.map((root) => join(root, ".claude", "agents")), join(configDir, "agents")].map(realPath);
}

export function postToolUse(
  session: () => Query | null,
  cwd: string,
  configDir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"),
): HookCallbackMatcher[] {
  const folders = agentFolders(cwd, configDir);
  const hook: HookCallback = async (input) => {
    const { file_path } = ((input as PostToolUseHookInput).tool_input ?? {}) as Record<string, unknown>;
    if (typeof file_path !== "string" || !file_path.endsWith(".md")) return {};
    const path = realPath(resolve(cwd, file_path));
    if (!folders.some((dir) => path.startsWith(dir + sep))) return {};
    let held: boolean;
    try {
      held = (await session()?.reloadPlugins({ holdOnCacheImpact: true }))?.held === true;
    } catch (err) {
      process.stderr.write(`could not reload the agents: ${err}\n`);
      return {};
    }
    return {
      hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: held ? HELD : NEXT_TURN },
    } satisfies HookJSONOutput;
  };
  return [{ matcher: "Write|Edit", hooks: [hook] }];
}
