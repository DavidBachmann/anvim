// Wire protocol between the anvim Lua plugin and this sidecar.
// One JSON object per line in each direction.

// What the code window shows when the user sends a prompt (context.ts).
// Paths are relative to the cwd, or absolute outside it. Lines are 1-based
// and inclusive.
export type PromptContext = {
  file?: string;
  cursor_line?: number;
  visible?: [number, number];
  selection?: { start_line: number; end_line: number; text: string; mode: "char" | "line" | "block" };
};

export type SlashCommand = { name: string; description: string; argument_hint?: string };

export type Command =
  | {
      type: "start";
      cwd: string;
      model?: string;
      permission_mode?: string;
      resume?: string;
      append_system_prompt?: string;
    }
  | { type: "prompt"; text: string; context?: PromptContext }
  | { type: "interrupt" }
  | { type: "set_permission_mode"; mode: string }
  | { type: "set_model"; model?: string }
  | { type: "preview_done"; req: number }
  // The answer to an editor_request: plain text for Claude, or an error.
  | { type: "editor_response"; req: number; result?: string; error?: string }
  // The user's answer to a permission_request (permissions.ts).
  | {
      type: "permission_response";
      req: number;
      behavior: "allow" | "deny";
      // Deny: what the user typed for Claude. Absent for a plain no.
      message?: string;
      // Allow: also apply what the request's remember label names.
      remember?: boolean;
      // AskUserQuestion: the chosen labels or typed text, per question text.
      answers?: Record<string, string[]>;
      // ExitPlanMode: the permission mode to work in after the plan.
      mode?: string;
    };

export type Event =
  | {
      type: "init";
      session_id: string;
      model: string;
      cwd: string;
      permission_mode: string;
      version: string;
      slash_commands: string[];
    }
  // The slash commands with descriptions, after start and whenever they change.
  | { type: "commands"; commands: SlashCommand[] }
  | { type: "turn_start" }
  | { type: "text_start" }
  | { type: "text_delta"; text: string }
  | { type: "text_stop" }
  | { type: "thinking_start" }
  | { type: "thinking_stop" }
  | { type: "tool_start"; id: string; name: string }
  | {
      type: "tool_field";
      id: string;
      name: string;
      key: string;
      phase: "start" | "delta" | "end";
      text?: string;
      value?: unknown;
    }
  | { type: "tool_input_end"; id: string }
  // Sent before an edit tool runs. The plugin answers preview_done once its
  // streamed preview has caught up, so the file never changes ahead of the view.
  | { type: "await_preview"; req: number; tool_use_id: string }
  // An editor tool call (tools.ts). The plugin answers with editor_response.
  | { type: "editor_request"; req: number; method: string; params: Record<string, unknown> }
  // Claude Code asks before a tool runs. The plugin answers with permission_response.
  | {
      type: "permission_request";
      req: number;
      tool_use_id?: string;
      tool: string;
      input: Record<string, unknown>;
      // The label of the "don't ask again" choice, which names what it allows.
      // Absent when there is nothing to remember.
      remember?: string;
      blocked_path?: string;
      title?: string;
      description?: string;
      // Open on "No", and approve with no single key.
      default_to_no?: boolean;
      // Set when a subagent runs the tool.
      agent_id?: string;
    }
  // The request was aborted, for example by an interrupt. The plugin drops it.
  | { type: "permission_cancel"; req: number }
  | {
      type: "tool_use";
      id: string;
      name: string;
      input: Record<string, unknown>;
      parent_id: string | null;
    }
  | {
      type: "tool_result";
      id: string;
      is_error: boolean;
      text: string;
      result?: unknown;
      parent_id: string | null;
    }
  | {
      type: "turn_end";
      subtype: string;
      is_error: boolean;
      duration_ms: number;
      cost_usd: number;
      num_turns: number;
    }
  | { type: "status"; status: string | null; permission_mode?: string }
  | { type: "notice"; level: "info" | "warn" | "error"; text: string }
  | { type: "exit"; code: number };
