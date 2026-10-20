// Wire protocol between the anvim Lua plugin and this sidecar.
// One JSON object per line in each direction.

export type Command =
  | {
      type: "start";
      cwd: string;
      model?: string;
      permission_mode?: string;
      resume?: string;
      append_system_prompt?: string;
    }
  | { type: "prompt"; text: string }
  | { type: "interrupt" }
  | { type: "set_permission_mode"; mode: string }
  | { type: "set_model"; model?: string }
  | { type: "preview_done"; req: number }
  // The answer to an editor_request: plain text for Claude, or an error.
  | { type: "editor_response"; req: number; result?: string; error?: string };

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
