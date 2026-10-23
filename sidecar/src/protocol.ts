// Wire protocol between the anvim Lua plugin and this sidecar.
// One JSON object per line in each direction.

import type { PermissionMode } from "@anthropic-ai/claude-agent-sdk";

// builtin marks Claude Code's own commands. A typed alias runs the command
// that has it as its name, when one exists.
export type SlashCommand = {
  name: string;
  description: string;
  argument_hint?: string;
  aliases?: string[];
  builtin?: boolean;
};

export type EffortLevel = "low" | "medium" | "high" | "xhigh" | "max";

// A plan limit: the percent used, and when it resets, in seconds since the epoch.
export type UsageLimit = { title: string; percent: number; resets_at?: number };
// Lines under a title, such as the session's totals or the last 24 hours.
export type UsageSection = { title: string; lines: string[] };
export type Usage = { session: UsageSection; limits: UsageLimit[]; windows: UsageSection[] };
// The Context tab: Claude Code's grid of the context window, its legend, and
// what fills it. A color is a Claude Code theme color, such as "claude".
export type ContextMark = { glyph: string; color: string };
export type ContextView = {
  title: string;
  grid: ContextMark[][];
  legend: (ContextMark & { text: string; dim?: boolean })[];
  sections: UsageSection[];
};
// The MCP tab: a server, its status and where it comes from. own marks
// anvim's editor tools, which always run.
export type McpServer = {
  name: string;
  status: string;
  scope?: string;
  where?: string;
  error?: string;
  tools: string[];
  own?: boolean;
};
// The Status tab's lines that Claude Code knows. mcp counts the servers by status.
export type SessionInfo = { version?: string; login?: string; organization?: string; email?: string; mcp: string };
// The Chrome tab: Claude Code's /chrome dialog. status is that of the
// claude-in-chrome server, and absent means that this session runs without
// it. skips_checks: the session started in bypass mode, so Claude Code tells
// the extension to act on sites without its permission checks.
export type ChromeState = {
  allowed: boolean;
  subscriber: boolean;
  wsl: boolean;
  installed: boolean;
  status: "connected" | "connecting" | "failed" | "disabled" | "absent";
  browser?: string;
  enabled_by_default: boolean;
  skips_checks: boolean;
  urls: { install: string; reconnect: string; permissions: string };
};

export type Command =
  | {
      type: "start";
      cwd: string;
      model?: string;
      effort?: EffortLevel;
      permission_mode?: PermissionMode;
      // The user named the mode. Without a sandbox, a mode that nobody chose
      // becomes default mode (startMode() in sandbox.ts).
      permission_mode_chosen?: boolean;
      // Claude Code's Bash sandbox (sandbox.ts). False turns it off, also
      // over the settings files.
      sandbox: boolean;
      // A session to go on with, or the latest one in cwd with `continue`.
      resume?: string;
      continue?: boolean;
      // Send the resumed session's messages as a history event first.
      history?: boolean;
      append_system_prompt?: string;
      // anvim runs with --debug: the editor tools include screenshot and reload.
      debug?: boolean;
      // Claude in Chrome: true is Claude Code's --chrome, false its
      // --no-chrome. Without it, Claude Code's "Enabled by default" decides.
      chrome?: boolean;
    }
  // Absolute paths of the images that the prompt's [Image #N] chips stand for.
  // id is a UUID, which Claude Code's prompt_state events name.
  | { type: "prompt"; text: string; images?: string[]; id?: string }
  | { type: "interrupt" }
  | { type: "set_permission_mode"; mode: PermissionMode }
  | { type: "set_model"; model?: string }
  // For the rest of the session. null is the default: the level of the user's
  // Claude Code settings for the model, else the model's, also after a switch.
  | { type: "set_effort"; effort: EffortLevel | null }
  // Answered with a models event.
  | { type: "list_models" }
  // Answered with a usage event.
  | { type: "usage" }
  // Answered with a session_info event.
  | { type: "session_info" }
  // Answered with a context_usage event.
  | { type: "context_usage" }
  // Both are answered with an mcp_servers event.
  | { type: "mcp_servers" }
  | { type: "mcp_action"; action: "reconnect" | "enable" | "disable"; server: string }
  // All but chrome_browsers are answered with a chrome event. chrome_default
  // sets "Enabled by default", which holds for the next sessions.
  | { type: "chrome" }
  | { type: "chrome_reconnect" }
  | { type: "chrome_default"; enabled: boolean }
  | { type: "chrome_browsers" }
  | { type: "chrome_select"; device_id: string }
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
      mode?: PermissionMode;
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
      // The commands whose UX Claude Code binds to its terminal.
      terminal_slash_commands?: string[];
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
  // A subagent's input never streams, so its event carries the agent, the
  // tool's name and its whole input (preview.ts).
  | {
      type: "await_preview";
      req: number;
      tool_use_id: string;
      agent_id?: string;
      name?: string;
      input?: Record<string, unknown>;
    }
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
      // Why anvim's own guard asks, such as "runs outside the sandbox"
      // (sandbox.ts). Such a request has no remember.
      reason?: string;
    }
  // The request was aborted, for example by an interrupt. The plugin drops it.
  | { type: "permission_cancel"; req: number }
  // anvim denied the first guarded call of an agent without asking, with a
  // hint for Claude (sendback.ts). The call's tool_result comes after it.
  | { type: "send_back"; tool_use_id: string; agent_id?: string; reason: string }
  // A subagent's tool calls have the id of the Agent tool call that started
  // it as parent_id, and the subagent's own id as agent_id.
  | {
      type: "tool_use";
      id: string;
      name: string;
      input: Record<string, unknown>;
      parent_id: string | null;
      agent_id?: string;
    }
  | {
      type: "tool_result";
      id: string;
      is_error: boolean;
      text: string;
      result?: unknown;
      parent_id: string | null;
      agent_id?: string;
    }
  // A subagent's text. Subagents send whole blocks, never deltas.
  | { type: "agent_text"; agent_id: string; parent_id: string | null; text: string }
  // A subagent started. tool_use_id is the Agent tool call that started it.
  // depth is 1 for a subagent of the main agent, and parent_agent_id names
  // the subagent that started a deeper one.
  | {
      type: "agent_start";
      agent_id: string;
      tool_use_id: string;
      description: string;
      subagent_type?: string;
      parent_agent_id?: string;
      depth: number;
      background: boolean;
    }
  // Sent before each of a subagent's tool calls. description says what it
  // does, such as "Editing alpha.js".
  | {
      type: "agent_progress";
      agent_id: string;
      description: string;
      tool_uses?: number;
      tokens?: number;
      last_tool?: string;
    }
  // A subagent ended. A background agent's Agent tool call returned when it
  // started, so this is its result. description is set in a resumed
  // session's history, which may lack the tool call.
  | {
      type: "agent_end";
      agent_id: string;
      tool_use_id?: string;
      status: "completed" | "failed" | "stopped";
      summary?: string;
      description?: string;
      tool_uses?: number;
      tokens?: number;
      duration_ms?: number;
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
  // The session starts in, or fell back to, this mode in place of the start
  // command's, because no sandbox runs.
  | { type: "start_mode"; mode: string }
  // A slash command's own output, such as the text of /cost.
  | { type: "output"; text: string }
  // /clear dropped the conversation. The init that follows has the new session id.
  | { type: "reset" }
  // Claude Code summarized the conversation to free context.
  | { type: "compact"; trigger?: string; pre_tokens?: number; post_tokens?: number }
  // How full the context window is, at start and after each turn.
  | { type: "context"; percent: number; tokens: number; max: number }
  // The effort level that the session uses, after start, after each model or
  // effort change, and after each turn. null for a model without effort.
  | { type: "effort"; level: EffortLevel | null }
  // After start, and as the answer to list_models. effort_levels is absent
  // for a model without effort levels.
  | {
      type: "models";
      models: { value: string; name: string; description: string; resolved?: string; effort_levels?: EffortLevel[] }[];
    }
  // The answer to usage, as /usage in Claude Code's terminal shows it. error
  // says why there is no answer.
  | { type: "usage"; usage?: Usage; error?: string }
  // Claude Code queued, started, completed or cancelled the prompt with this
  // id. A prompt sent mid-turn starts after a tool result, or after the turn.
  | { type: "prompt_state"; id: string; state: string }
  // The email of Claude Code's login, at start.
  | { type: "account"; email?: string }
  // The MCP servers, for the MCP tab. After an action that failed, error says why.
  | { type: "mcp_servers"; servers?: McpServer[]; error?: string }
  // The answer to context_usage, for the Context tab.
  | { type: "context_usage"; context?: ContextView; error?: string }
  // The answer to session_info, for the Status tab.
  | { type: "session_info"; info?: SessionInfo; error?: string }
  // The Chrome tab's state. message says what the last action did, in the
  // words of Claude Code's /chrome dialog.
  | { type: "chrome"; chrome?: ChromeState; message?: { text: string; level: "info" | "error" }; error?: string }
  // The browsers that the extension connected. current is the one in use.
  | {
      type: "chrome_browsers";
      browsers?: { device_id: string; name: string; os?: string; current: boolean }[];
      error?: string;
    }
  // A resumed session's past, sent before it starts. Its events draw the
  // transcript as live ones do. A "user" event is a past prompt. An event
  // that starts an item has the time that Claude Code saved, in seconds since
  // the epoch.
  | { type: "history"; session_id: string; events: ((Event | { type: "user"; text: string }) & { time?: number })[] };
