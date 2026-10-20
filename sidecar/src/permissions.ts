// Permission prompts. Claude Code calls canUseTool before a tool runs that
// needs the user's yes. Each call becomes a permission_request, and the plugin
// (lua/anvim/permission.lua) answers with a permission_response.
import type {
  CanUseTool,
  PermissionMode,
  PermissionResult,
  PermissionUpdate,
  PermissionUpdateDestination,
} from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import { isAbsolute, relative, sep } from "node:path";
import type { Command, Event } from "./protocol";
import { isEditorTool } from "./tools";

type Response = Extract<Command, { type: "permission_response" }>;
type Input = Record<string, unknown>;

// Claude Code's own wording, so Claude reacts as it does in the terminal.
const REJECTED =
  "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file).";
export const REJECT = `${REJECTED} STOP what you are doing and wait for the user to tell you how to proceed.`;
export const REJECT_WITH = `${REJECTED} To tell you how to proceed, the user said:\n`;
export const CANCELLED = "The permission request was cancelled before the user answered.";

type Pending = {
  tool: string;
  input: Input;
  suggestions?: PermissionUpdate[];
  resolve: (result: PermissionResult) => void;
};

// Matches the plugin's answers to Claude Code's requests. A request stays open
// until the user answers or Claude Code aborts it.
export class PermissionBridge {
  private pending = new Map<number, Pending>();
  private next = 1;
  // Directories in labels are relative to it.
  cwd = process.cwd();
  // A session that started in bypass mode can switch back to it after a plan.
  bypass = false;

  constructor(private emit: (ev: Event) => void) {}

  canUseTool: CanUseTool = (tool, input, opts) => {
    // Read-only editor tools need no prompt (tools.ts).
    if (isEditorTool(opts.mcpServer)) return Promise.resolve({ behavior: "allow", updatedInput: input });
    const req = this.next++;
    const remember =
      !opts.suppressAlwaysAllowRule && opts.suggestions?.length ? rememberLabel(opts.suggestions, this.cwd) : undefined;
    const suggestions = remember ? opts.suggestions : undefined;
    return new Promise((resolve) => {
      const abort = () => {
        if (!this.pending.delete(req)) return;
        this.emit({ type: "permission_cancel", req });
        resolve({ behavior: "deny", message: CANCELLED });
      };
      this.pending.set(req, {
        tool,
        input,
        suggestions,
        resolve: (result) => {
          opts.signal.removeEventListener("abort", abort);
          resolve(result);
        },
      });
      this.emit({
        type: "permission_request",
        req,
        tool_use_id: opts.toolUseID,
        tool,
        input,
        remember,
        blocked_path: opts.blockedPath,
        title: opts.title,
        description: opts.description,
        default_to_no: opts.defaultToNo || undefined,
        agent_id: opts.agentID,
      });
      if (opts.signal.aborted) abort();
      else opts.signal.addEventListener("abort", abort, { once: true });
    });
  };

  respond(res: Response): void {
    const p = this.pending.get(res.req);
    if (!p) return;
    this.pending.delete(res.req);
    // A mode switch reaches the plugin as a status event from Claude Code.
    p.resolve(decide(p, res, this.bypass));
  }

  get waiting(): number {
    return this.pending.size;
  }
}

function decide(p: Pending, res: Response, bypass: boolean): PermissionResult {
  if (res.behavior === "deny") {
    const message = res.message?.trim();
    return {
      behavior: "deny",
      message: message ? REJECT_WITH + message : REJECT,
      decisionClassification: "user_reject",
    };
  }
  if (p.tool === "AskUserQuestion") {
    const answers: Record<string, string> = {};
    for (const [question, parts] of Object.entries(res.answers ?? {})) {
      if (parts.length) answers[question] = joinAnswer(parts);
    }
    return { behavior: "allow", updatedInput: { ...p.input, answers }, decisionClassification: "user_temporary" };
  }
  const modes = bypass ? ["default", "acceptEdits", "bypassPermissions"] : ["default", "acceptEdits"];
  if (p.tool === "ExitPlanMode" && res.mode && modes.includes(res.mode)) {
    return {
      behavior: "allow",
      updatedInput: p.input,
      updatedPermissions: [{ type: "setMode", mode: res.mode as PermissionMode, destination: "session" }],
      decisionClassification: "user_temporary",
    };
  }
  if (res.remember && p.suggestions) {
    return {
      behavior: "allow",
      updatedInput: p.input,
      updatedPermissions: p.suggestions,
      decisionClassification: "user_permanent",
    };
  }
  return { behavior: "allow", updatedInput: p.input, decisionClassification: "user_temporary" };
}

// Claude Code joins the labels of a multi-select answer with ", ". It quotes a
// label that holds ", " or a quote, so that it can split them again.
export function joinAnswer(parts: string[]): string {
  return parts.map((part) => (part.includes(", ") || part.includes('"') ? JSON.stringify(part) : part)).join(", ");
}

const PLACES: Record<PermissionUpdateDestination, string> = {
  session: "during this session",
  cliArg: "during this session",
  localSettings: "in this project",
  projectSettings: "in this project",
  userSettings: "in every project",
};

// A directory as the user knows it: relative to the cwd, or under ~.
function shortDir(dir: string, cwd: string): string {
  const rel = relative(cwd, dir);
  if (rel === "") return "this directory";
  if (!rel.startsWith("..") && !isAbsolute(rel)) return rel;
  const home = homedir();
  return dir === home || dir.startsWith(home + sep) ? "~" + dir.slice(home.length) : dir;
}

// The label of the "don't ask again" choice. Choosing it applies every
// suggestion, so the label names each one, in Claude Code's settings syntax.
export function rememberLabel(suggestions: PermissionUpdate[], cwd: string): string | undefined {
  const parts: string[] = [];
  let edits = false;
  for (const s of suggestions) {
    const place = PLACES[s.destination];
    if (s.type === "addRules" && s.behavior === "allow" && s.rules.length) {
      const rules = s.rules.map((r) => (r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName));
      parts.push(`${rules.join(", ")} ${place}`);
    } else if (s.type === "addDirectories" && s.directories.length) {
      parts.push(`access to ${s.directories.map((d) => shortDir(d, cwd)).join(", ")} ${place}`);
    } else if (s.type === "setMode" && s.mode === "acceptEdits") {
      edits = true;
    } else {
      // A suggestion the label cannot name is not offered.
      return undefined;
    }
  }
  if (parts.length === 0) return edits ? "Yes, allow all edits during this session" : undefined;
  if (edits) parts.push("all edits during this session");
  return `Yes, and don't ask again for ${parts.join(", ")}`;
}
