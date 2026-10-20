import type { SDKMessage, SlashCommand as SdkSlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { FieldStream } from "./fieldstream";
import type { Event } from "./protocol";

const MAX_TEXT = 2000;

type Block =
  | { type: "text" }
  | { type: "thinking" }
  | { type: "tool_use"; id: string; name: string; fields: FieldStream }
  | { type: "other" };

type AnyRecord = Record<string, any>;

// Turns the SDK message stream into anvim events. Stateful: it tracks the
// open content blocks of the main session's current message.
export class Translator {
  private blocks = new Map<number, Block>();
  private inTurn = false;

  translate(msg: SDKMessage): Event[] {
    const m = msg as AnyRecord;
    const out: Event[] = [];
    if (!this.inTurn && (m.type === "stream_event" || m.type === "assistant")) {
      this.inTurn = true;
      out.push({ type: "turn_start" });
    }
    switch (m.type) {
      case "system":
        this.system(m, out);
        break;
      case "stream_event":
        if (m.parent_tool_use_id == null) this.streamEvent(m.event, out);
        break;
      case "assistant":
        this.assistant(m, out);
        break;
      case "user":
        this.user(m, out);
        break;
      case "result":
        this.inTurn = false;
        this.blocks.clear();
        out.push({
          type: "turn_end",
          subtype: m.subtype,
          is_error: Boolean(m.is_error),
          duration_ms: m.duration_ms ?? 0,
          cost_usd: m.total_cost_usd ?? 0,
          num_turns: m.num_turns ?? 0,
        });
        if (m.subtype !== "success" && Array.isArray(m.errors) && m.errors.length) {
          out.push({ type: "notice", level: "error", text: m.errors.join("\n") });
        }
        break;
    }
    return out;
  }

  private system(m: AnyRecord, out: Event[]): void {
    if (m.subtype === "init") {
      out.push({
        type: "init",
        session_id: m.session_id,
        model: m.model,
        cwd: m.cwd,
        permission_mode: m.permissionMode,
        version: m.claude_code_version,
        slash_commands: m.slash_commands ?? [],
      });
    } else if (m.subtype === "commands_changed" && Array.isArray(m.commands)) {
      out.push(commandsEvent(m.commands));
    } else if (m.subtype === "status") {
      out.push({ type: "status", status: m.status ?? null, permission_mode: m.permissionMode });
    } else if (m.subtype === "api_retry") {
      out.push({
        type: "notice",
        level: "warn",
        text: `API retry ${m.attempt}/${m.max_retries} in ${Math.round(m.retry_delay_ms / 1000)}s`,
      });
    }
  }

  private streamEvent(e: AnyRecord, out: Event[]): void {
    if (e.type === "content_block_start") {
      const cb = e.content_block;
      if (cb.type === "text") {
        this.blocks.set(e.index, { type: "text" });
        out.push({ type: "text_start" });
      } else if (cb.type === "thinking" || cb.type === "redacted_thinking") {
        this.blocks.set(e.index, { type: "thinking" });
        out.push({ type: "thinking_start" });
      } else if (cb.type === "tool_use") {
        this.blocks.set(e.index, { type: "tool_use", id: cb.id, name: cb.name, fields: new FieldStream() });
        out.push({ type: "tool_start", id: cb.id, name: cb.name });
      } else {
        this.blocks.set(e.index, { type: "other" });
      }
    } else if (e.type === "content_block_delta") {
      const block = this.blocks.get(e.index);
      const d = e.delta;
      if (d.type === "text_delta" && d.text) {
        out.push({ type: "text_delta", text: d.text });
      } else if (d.type === "input_json_delta" && block?.type === "tool_use") {
        for (const f of block.fields.push(d.partial_json ?? "")) {
          const ev: Event = { type: "tool_field", id: block.id, name: block.name, key: f.key, phase: f.kind };
          if (f.kind === "delta") ev.text = f.text;
          if (f.kind === "end") ev.value = f.value;
          out.push(ev);
        }
      }
    } else if (e.type === "content_block_stop") {
      const block = this.blocks.get(e.index);
      this.blocks.delete(e.index);
      if (block?.type === "text") out.push({ type: "text_stop" });
      else if (block?.type === "thinking") out.push({ type: "thinking_stop" });
      else if (block?.type === "tool_use") out.push({ type: "tool_input_end", id: block.id });
    } else if (e.type === "message_stop") {
      // A cut stream leaves tool blocks open; their input is incomplete.
      for (const block of this.blocks.values()) {
        if (block.type === "tool_use") out.push({ type: "tool_input_end", id: block.id });
      }
      this.blocks.clear();
    }
  }

  private assistant(m: AnyRecord, out: Event[]): void {
    const parent = m.parent_tool_use_id ?? null;
    for (const block of m.message?.content ?? []) {
      if (block.type === "tool_use") {
        out.push({ type: "tool_use", id: block.id, name: block.name, input: block.input ?? {}, parent_id: parent });
      }
    }
    if (m.error) out.push({ type: "notice", level: "error", text: String(m.error) });
  }

  private user(m: AnyRecord, out: Event[]): void {
    const content = m.message?.content;
    if (!Array.isArray(content)) return;
    for (const block of content) {
      if (block.type !== "tool_result") continue;
      out.push({
        type: "tool_result",
        id: block.tool_use_id,
        is_error: Boolean(block.is_error),
        text: truncate(resultText(block.content)),
        result: trim(m.tool_use_result),
        parent_id: m.parent_tool_use_id ?? null,
      });
    }
  }
}

export function commandsEvent(commands: SdkSlashCommand[]): Event {
  return {
    type: "commands",
    commands: commands.map((c) => ({
      name: c.name,
      description: c.description ?? "",
      ...(c.argumentHint ? { argument_hint: c.argumentHint } : {}),
    })),
  };
}

function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b: AnyRecord) => b.type === "text")
    .map((b: AnyRecord) => b.text)
    .join("\n");
}

function truncate(s: string): string {
  return s.length > MAX_TEXT ? s.slice(0, MAX_TEXT) + "..." : s;
}

// Tool results can hold whole files. The plugin only needs the metadata.
function trim(value: unknown): unknown {
  if (typeof value === "string") return truncate(value);
  if (Array.isArray(value)) return value.map(trim);
  if (value && typeof value === "object") {
    const out: AnyRecord = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "originalFile") continue;
      out[k] = trim(v);
    }
    return out;
  }
  return value;
}
