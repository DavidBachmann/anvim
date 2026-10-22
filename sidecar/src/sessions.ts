// Claude Code's saved sessions for a directory, read through the Agent SDK.
// anvim never writes them. As a script, it prints the list for the picker:
//   bun src/sessions.ts list <dir>
import { getSessionInfo, getSessionMessages, listSessions, type SessionMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import { commandOutput, readResult, resultText, truncate, truncateOutput } from "./translate";

export type SessionItem = {
  id: string;
  title: string;
  modified: number;
  created?: number;
  size?: number;
  branch?: string;
  first_prompt?: string;
};

type HistoryEvent = Extract<Event, { type: "history" }>["events"][number];
type AnyRecord = Record<string, any>;

// Only this directory's own sessions: a session of another worktree would not
// resume here.
export async function list(cwd: string): Promise<SessionItem[]> {
  const sessions = await listSessions({ dir: cwd, includeWorktrees: false });
  return sessions.map((s) => ({
    id: s.sessionId,
    title: s.customTitle || s.summary || s.firstPrompt || "(no prompt)",
    modified: s.lastModified,
    created: s.createdAt,
    size: s.fileSize,
    branch: s.gitBranch,
    first_prompt: s.firstPrompt,
  }));
}

export async function latest(cwd: string): Promise<string | undefined> {
  return (await listSessions({ dir: cwd, includeWorktrees: false, limit: 1 }))[0]?.sessionId;
}

export async function exists(id: string, cwd: string): Promise<boolean> {
  return (await getSessionInfo(id, { dir: cwd })) !== undefined;
}

export async function history(id: string, cwd: string): Promise<HistoryEvent[]> {
  return historyEvents(await getSessionMessages(id, { dir: cwd }));
}

const STATUSES: Record<string, "completed" | "failed" | "stopped"> = {
  completed: "completed",
  failed: "failed",
  stopped: "stopped",
  killed: "stopped",
};

// Claude Code saves the end of a background task as a user message. An
// agent's end draws as it does live, and other tasks send nothing, as live.
function notification(content: string): HistoryEvent | undefined {
  const tag = (name: string) => content.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1]?.trim();
  const num = (name: string) => {
    const n = Number(tag(name) || NaN);
    return Number.isNaN(n) ? undefined : n;
  };
  const description = tag("summary")?.match(/^Agent "(.*)"/)?.[1];
  const id = tag("task-id");
  if (description === undefined || !id) return undefined;
  const result = tag("result");
  return {
    type: "agent_end",
    agent_id: id,
    tool_use_id: tag("tool-use-id"),
    status: STATUSES[tag("status") ?? ""] ?? "completed",
    description,
    summary: result ? truncate(result) : undefined,
    tool_uses: num("tool_uses"),
    tokens: num("subagent_tokens") ?? num("total_tokens"),
    duration_ms: num("duration_ms"),
  };
}

// A prompt as the user typed it. Slash commands are saved as tags, and an
// interrupt as Claude Code's own marker text.
function prompt(content: string): HistoryEvent | undefined {
  if (content.trimStart().startsWith("<task-notification>")) return notification(content);
  if (/^\[Request interrupted by user[^\]]*\]$/.test(content.trim())) {
    return { type: "notice", level: "warn", text: "Interrupted by user" };
  }
  const output = commandOutput(content);
  if (output !== undefined) return output === "" ? undefined : { type: "output", text: truncateOutput(output) };
  const name = content.match(/<command-name>(.*?)<\/command-name>/)?.[1];
  if (name) {
    // A session that /clear started begins with the /clear itself.
    if (name === "/clear") return undefined;
    const args = content.match(/<command-args>([\s\S]*?)<\/command-args>/)?.[1]?.trim();
    return { type: "user", text: args ? `${name} ${args}` : name };
  }
  return content.trim() === "" ? undefined : { type: "user", text: content };
}

// When Claude Code saved a message, in seconds since the epoch. The SDK
// returns each message's timestamp, but its SessionMessage type leaves it out.
function savedAt(m: SessionMessage): number | undefined {
  const stamp = (m as { timestamp?: unknown }).timestamp;
  const ms = typeof stamp === "string" ? Date.parse(stamp) : NaN;
  return Number.isNaN(ms) ? undefined : Math.floor(ms / 1000);
}

// The events that draw these messages, in the order they happened. Subagent
// messages live in their own files, so they are not here. An event that
// starts an item has the message's time.
export function historyEvents(messages: SessionMessage[]): HistoryEvent[] {
  const out: HistoryEvent[] = [];
  const names = new Map<string, string>();
  for (const m of messages) {
    const raw = m as AnyRecord;
    const content = (m.message as AnyRecord | undefined)?.content;
    const time = savedAt(m);
    // A slash command's output goes under its prompt, as no item of its own.
    const at = (ev: HistoryEvent): HistoryEvent =>
      time === undefined || ev.type === "output" ? ev : { ...ev, time };
    if (m.parent_tool_use_id != null) continue;
    if (raw.isCompactSummary) {
      out.push(at({ type: "compact" }));
      continue;
    }
    if (raw.is_meta || raw.isMeta) continue;
    if (m.type === "assistant" && Array.isArray(content)) {
      for (const block of content) {
        if (block.type === "text" && block.text) {
          out.push(at({ type: "text_start" }), { type: "text_delta", text: block.text }, { type: "text_stop" });
        } else if (block.type === "tool_use") {
          names.set(block.id, block.name);
          out.push(at({ type: "tool_use", id: block.id, name: block.name, input: block.input ?? {}, parent_id: null }));
        }
      }
    } else if (m.type === "user") {
      if (typeof content === "string") {
        const ev = prompt(content);
        if (ev) out.push(at(ev));
      } else if (Array.isArray(content)) {
        const texts: string[] = [];
        for (const block of content) {
          if (block.type === "tool_result") {
            const text = resultText(block.content);
            out.push({
              type: "tool_result",
              id: block.tool_use_id,
              is_error: Boolean(block.is_error),
              text: truncate(text),
              result: names.get(block.tool_use_id) === "Read" ? readResult(text) : undefined,
              parent_id: null,
            });
          } else if (block.type === "text" && block.text) {
            texts.push(block.text);
          } else if (block.type === "image") {
            texts.push("[Image]");
          }
        }
        const ev = texts.length ? prompt(texts.join("\n")) : undefined;
        if (ev) out.push(at(ev));
      }
    }
  }
  return out;
}

if (import.meta.main) {
  const [cmd, dir] = process.argv.slice(2);
  if (cmd !== "list" || !dir) {
    process.stderr.write("usage: sessions.ts list <dir>\n");
    process.exit(2);
  }
  process.stdout.write(JSON.stringify(await list(dir)) + "\n");
}
