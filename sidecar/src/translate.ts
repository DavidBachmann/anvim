import type {
  AccountInfo,
  McpServerStatus,
  ModelInfo,
  SDKControlGetContextUsageResponse,
  SDKControlGetUsageResponse,
  SDKMessage,
  SlashCommand as SdkSlashCommand,
} from "@anthropic-ai/claude-agent-sdk";
import { FieldStream } from "./fieldstream";
import type { ContextMark, Event, McpServer, UsageSection } from "./protocol";
import { tildePath } from "./sandbox";
import { isEditorTool } from "./tools";

const MAX_TEXT = 2000;
// A subagent's reply can be long.
const MAX_AGENT_TEXT = 8000;
// A local command such as /context prints about 10k characters of tables.
const MAX_OUTPUT = 20000;
// Claude Code's model name on the messages that it writes itself, such as a
// slash command's output.
const SYNTHETIC = "<synthetic>";

type Block =
  | { type: "text" }
  | { type: "thinking" }
  | { type: "tool_use"; id: string; name: string; fields: FieldStream }
  | { type: "other" };

export type AnyRecord = Record<string, any>;

// A message of the main agent's own conversation. Background subagents send
// their messages between the main agent's turns too, as do the task messages
// that report on them.
export function mainThread(msg: SDKMessage): boolean {
  const m = msg as AnyRecord;
  if (m.parent_tool_use_id != null || m.agent_id) return false;
  return !(m.type === "system" && (m.subtype?.startsWith("task_") || m.subtype === "background_tasks_changed"));
}

// Turns the SDK message stream into anvim events. Stateful: it tracks the
// open content blocks of the main session's current message.
export class Translator {
  private blocks = new Map<number, Block>();
  private inTurn = false;
  // /compact prints "Compacted" after the compact boundary, which says more.
  private compacted = false;
  // The task ids of running subagents. Only task_started names a task's type,
  // and shells and other tasks send task messages too.
  private agents = new Set<string>();
  // The running agents that started in the background.
  private background = new Set<string>();
  // The names of subagent tool calls that wait for their result. A subagent's
  // result has no tool_use_result, so a Read's line count comes from its text.
  private agentTools = new Map<string, string>();
  // The context window of each model, from the turns' results.
  private windows = new Map<string, number>();
  // The main agent's window, for a model that no result named yet.
  defaultWindow?: number;
  // Each subagent's model, the tokens in its context after its last
  // response, and the window that its last agent_context used.
  private contexts = new Map<string, { model: string; tokens: number; max?: number }>();

  translate(msg: SDKMessage): Event[] {
    const m = msg as AnyRecord;
    const out: Event[] = [];
    if (!this.inTurn && (m.type === "stream_event" || m.type === "assistant") && mainThread(msg)) {
      this.inTurn = true;
      out.push({ type: "turn_start" });
    }
    switch (m.type) {
      case "system":
        this.system(m, out);
        break;
      case "conversation_reset":
        this.contexts.clear();
        out.push({ type: "reset" });
        break;
      case "command_lifecycle":
        if (typeof m.command_uuid === "string") out.push({ type: "prompt_state", id: m.command_uuid, state: String(m.state) });
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
        this.compacted = false;
        this.blocks.clear();
        out.push({
          type: "turn_end",
          subtype: m.subtype,
          is_error: Boolean(m.is_error),
          duration_ms: m.duration_ms ?? 0,
          cost_usd: m.total_cost_usd ?? 0,
          num_turns: m.num_turns ?? 0,
        });
        this.learnWindows(m, out);
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
        ...(Array.isArray(m.terminal_slash_commands) ? { terminal_slash_commands: m.terminal_slash_commands } : {}),
      });
    } else if (m.subtype === "commands_changed" && Array.isArray(m.commands)) {
      out.push(commandsEvent(m.commands));
    } else if (m.subtype === "local_command_output" && typeof m.content === "string" && m.content.trim()) {
      out.push({ type: "output", text: truncateOutput(m.content.trim()) });
    } else if (m.subtype === "status") {
      out.push({ type: "status", status: m.status ?? null, permission_mode: m.permissionMode });
      if (m.compact_result === "failed") {
        out.push({ type: "notice", level: "error", text: `Compaction failed: ${m.compact_error ?? "no reason given"}` });
      }
    } else if (m.subtype === "compact_boundary") {
      const meta = m.compact_metadata ?? {};
      this.compacted = true;
      out.push({ type: "compact", trigger: meta.trigger ?? "auto", pre_tokens: meta.pre_tokens, post_tokens: meta.post_tokens });
    } else if (m.subtype === "api_retry") {
      out.push({
        type: "notice",
        level: "warn",
        text: `API retry ${m.attempt}/${m.max_retries} in ${Math.round(m.retry_delay_ms / 1000)}s`,
      });
    } else if (m.subtype?.startsWith("task_")) {
      this.task(m, out);
    } else if (m.subtype === "background_tasks_changed") {
      this.backgroundTasks(m, out);
    }
  }

  // An ambient task is housekeeping, which Claude Code shows no activity for.
  // The list of background tasks is the level signal: a background agent that
  // left it has ended, even when its task_notification never came.
  private backgroundTasks(m: AnyRecord, out: Event[]): void {
    const live = new Set((m.tasks ?? []).map((t: AnyRecord) => t.task_id));
    for (const id of this.background) {
      if (live.has(id)) continue;
      this.background.delete(id);
      this.agents.delete(id);
      out.push({ type: "agent_end", agent_id: id, status: "completed" });
    }
  }

  private task(m: AnyRecord, out: Event[]): void {
    const id = m.task_id;
    if (m.subtype === "task_started") {
      if (m.task_type !== "local_agent" || m.ambient || !m.tool_use_id) return;
      this.agents.add(id);
      if (m.is_backgrounded) this.background.add(id);
      out.push({
        type: "agent_start",
        agent_id: id,
        tool_use_id: m.tool_use_id,
        description: m.description ?? "",
        ...(m.subagent_type ? { subagent_type: m.subagent_type } : {}),
        ...(m.parent_task_id ? { parent_agent_id: m.parent_task_id } : {}),
        depth: m.spawn_depth ?? 1,
        background: Boolean(m.is_backgrounded),
      });
    } else if (!this.agents.has(id)) {
      return;
    } else if (m.subtype === "task_updated") {
      if (m.patch?.is_backgrounded !== true || this.background.has(id)) return;
      this.background.add(id);
      out.push({ type: "agent_background", agent_id: id });
    } else if (m.subtype === "task_progress") {
      out.push({
        type: "agent_progress",
        agent_id: id,
        description: m.description ?? "",
        tool_uses: m.usage?.tool_uses,
        tokens: m.usage?.total_tokens,
        last_tool: m.last_tool_name,
      });
    } else if (m.subtype === "task_notification") {
      this.agents.delete(id);
      this.background.delete(id);
      out.push({
        type: "agent_end",
        agent_id: id,
        ...(m.tool_use_id ? { tool_use_id: m.tool_use_id } : {}),
        status: m.status,
        ...(m.summary ? { summary: truncate(m.summary) } : {}),
        ...(m.usage ? { tool_uses: m.usage.tool_uses, tokens: m.usage.total_tokens, duration_ms: m.usage.duration_ms } : {}),
      });
    }
  }

  // A subagent's context after a response holds the response's prompt and
  // its output.
  private agentUsage(id: string, message: AnyRecord, out: Event[]): void {
    const u = message.usage;
    const tokens =
      (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.output_tokens ?? 0);
    const entry = { model: String(message.model ?? ""), tokens };
    this.contexts.set(id, entry);
    this.agentContext(id, entry, out);
  }

  private agentContext(id: string, entry: { model: string; tokens: number; max?: number }, out: Event[]): void {
    entry.max = this.windows.get(entry.model) ?? this.defaultWindow;
    const percent = entry.max ? { max: entry.max, percent: Math.round((entry.tokens / entry.max) * 100) } : {};
    out.push({ type: "agent_context", agent_id: id, tokens: entry.tokens, ...percent });
  }

  // A result names the window of each model that ran. A subagent whose
  // percent came from another window gets it again.
  private learnWindows(m: AnyRecord, out: Event[]): void {
    for (const [model, usage] of Object.entries<AnyRecord>(m.modelUsage ?? {})) {
      if (usage?.contextWindow > 0) this.windows.set(model, usage.contextWindow);
    }
    for (const [id, entry] of this.contexts) {
      if ((this.windows.get(entry.model) ?? this.defaultWindow) !== entry.max) this.agentContext(id, entry, out);
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
    const synthetic = m.message?.model === SYNTHETIC;
    const failed = m.error || (synthetic && m.is_api_error_message);
    // A slash command such as /usage answers with a message of its own, which
    // streams no text.
    if (synthetic && !failed && mainThread(m as SDKMessage)) {
      const text = resultText(m.message.content).trim();
      if (text) out.push({ type: "output", text: truncateOutput(text) });
      return;
    }
    const parent = m.parent_tool_use_id ?? null;
    const agent = mainThread(m as SDKMessage) ? undefined : m.agent_id;
    if (agent && !synthetic && m.message?.usage) this.agentUsage(agent, m.message, out);
    for (const block of m.message?.content ?? []) {
      // The main agent's text streamed already. A subagent's comes whole.
      if (agent && block.type === "text" && block.text?.trim()) {
        out.push({ type: "agent_text", agent_id: agent, parent_id: parent, text: truncate(block.text, MAX_AGENT_TEXT) });
      } else if (block.type === "tool_use") {
        if (agent) this.agentTools.set(block.id, block.name);
        out.push({
          type: "tool_use",
          id: block.id,
          name: block.name,
          input: block.input ?? {},
          parent_id: parent,
          ...agentOf(m),
        });
      }
    }
    // A synthetic error says in its text what went wrong. Its code, such as
    // server_error, names only the kind.
    if (failed) {
      const text = synthetic ? resultText(m.message.content).trim() : "";
      out.push({ type: "notice", level: "error", text: truncate(text || String(m.error ?? "API error")) });
    }
  }

  private user(m: AnyRecord, out: Event[]): void {
    const content = m.message?.content;
    if (typeof content === "string" && m.parent_tool_use_id == null) {
      const text = commandOutput(content);
      if (text !== undefined && !this.compacted && text !== "") out.push({ type: "output", text: truncateOutput(text) });
      if (text !== undefined) this.compacted = false;
      return;
    }
    if (!Array.isArray(content)) return;
    for (const block of content) {
      if (block.type !== "tool_result") continue;
      const text = resultText(block.content);
      const name = this.agentTools.get(block.tool_use_id);
      this.agentTools.delete(block.tool_use_id);
      out.push({
        type: "tool_result",
        id: block.tool_use_id,
        is_error: Boolean(block.is_error),
        text: truncate(text),
        result: name === "Read" && !block.is_error ? readResult(text) : trim(m.tool_use_result),
        parent_id: m.parent_tool_use_id ?? null,
        ...agentOf(m),
      });
    }
  }
}

function agentOf(m: AnyRecord): { agent_id?: string } {
  return m.agent_id ? { agent_id: m.agent_id } : {};
}

export function commandsEvent(commands: SdkSlashCommand[]): Event {
  return {
    type: "commands",
    commands: commands.map((c) => ({
      name: c.name,
      description: c.description ?? "",
      ...(c.argumentHint ? { argument_hint: c.argumentHint } : {}),
      ...(c.aliases?.length ? { aliases: c.aliases } : {}),
      ...(c.builtin ? { builtin: true } : {}),
    })),
  };
}

export function modelsEvent(models: ModelInfo[]): Event {
  return {
    type: "models",
    models: models.map((m) => ({
      value: m.value,
      name: m.displayName,
      description: m.description,
      resolved: m.resolvedModel,
      ...(m.supportsEffort && m.supportedEffortLevels?.length ? { effort_levels: m.supportedEffortLevels } : {}),
    })),
  };
}

// Claude Code's words for what used the plan, by key.
const BEHAVIORS: Record<string, string> = {
  subagent_heavy: "came from subagent-heavy sessions",
  long_context: "was at >150k context",
  cron: "came from sessions active for 8+ hours",
  cache_miss: "hit a >100k-token cache miss",
  high_parallel: "was while 4+ sessions ran in parallel",
  max_effort: "was at max effort",
  workflow: "came from workflows",
  always_on_context: "went to always-on context over 40k tokens",
  large_tool_results: "went to tool results over 10k tokens",
};

type UsageWindowAnswer = NonNullable<SDKControlGetUsageResponse["behaviors"]>["day"];

function usageWindow(title: string, w: UsageWindowAnswer): UsageSection {
  const top = (label: string, rows: { name: string; pct: number }[]) =>
    rows.length ? [`Top ${label}: ${rows.map((r) => `${r.name} ${r.pct}%`).join(", ")}`] : [];
  return {
    title: `${title} · ${w.request_count} requests · ${w.session_count} sessions`,
    lines: [
      ...w.behaviors.flatMap((b) => (BEHAVIORS[b.key] ? [`${b.pct}% of your usage ${BEHAVIORS[b.key]}`] : [])),
      ...top("subagents", w.agents),
      ...top("skills", w.skills),
      ...top("plugins", w.plugins),
      ...top("MCP servers", w.mcp_servers),
    ],
  };
}

// 11h 50m 1s, as Claude Code writes a duration.
function duration(ms: number): string {
  const s = Math.round(ms / 1000);
  const [h, m] = [Math.floor(s / 3600), Math.floor((s % 3600) / 60)];
  return h ? `${h}h ${m}m ${s % 60}s` : m ? `${m}m ${s % 60}s` : `${s}s`;
}

// 14.4m, 1m, 1.4k or 25 tokens.
function tokens(n: number): string {
  const short = (x: number, unit: string) => `${x.toFixed(1).replace(/\.0$/, "")}${unit}`;
  return n >= 1e6 ? short(n / 1e6, "m") : n >= 1e3 ? short(n / 1e3, "k") : String(Math.round(n));
}

const dollars = (usd: number) => `$${usd.toFixed(usd >= 0.5 || usd === 0 ? 2 : 4)}`;

function sessionSection(s: SDKControlGetUsageResponse["session"]): UsageSection {
  const models = Object.entries(s.model_usage ?? {}).map(
    ([name, m]) =>
      `  ${name}: ${tokens(m.inputTokens)} input, ${tokens(m.outputTokens)} output, ` +
      `${tokens(m.cacheReadInputTokens)} cache read, ${tokens(m.cacheCreationInputTokens)} cache write (${dollars(m.costUSD)})`,
  );
  return {
    title: "Session",
    lines: [
      `Total cost: ${dollars(s.total_cost_usd)}`,
      `Total duration (API): ${duration(s.total_api_duration_ms)}`,
      `Total duration (wall): ${duration(s.total_duration_ms)}`,
      `Total code changes: ${s.total_lines_added} lines added, ${s.total_lines_removed} lines removed`,
      ...(models.length ? ["Usage by model:", ...models] : []),
    ],
  };
}

// The limits that Claude Code's /usage dialog shows, in its order.
export function usageEvent(u: SDKControlGetUsageResponse): Event {
  const rl = u.rate_limits;
  const limits = [
    { title: "Current session", limit: rl?.five_hour },
    { title: "Current week (all models)", limit: rl?.seven_day },
    { title: "Current week (Sonnet only)", limit: rl?.seven_day_sonnet },
    ...(rl?.model_scoped ?? []).map((m) => ({ title: `Current week (${m.display_name})`, limit: m })),
  ].flatMap(({ title, limit }) => {
    if (limit?.utilization == null) return [];
    const resets = Date.parse(limit.resets_at ?? "") / 1000;
    return [{ title, percent: limit.utilization, ...(Number.isFinite(resets) ? { resets_at: Math.floor(resets) } : {}) }];
  });
  const b = u.behaviors;
  return {
    type: "usage",
    usage: {
      session: sessionSection(u.session),
      limits,
      windows: b ? [usageWindow("Last 24h", b.day), usageWindow("Last 7d", b.week)] : [],
    },
  };
}

// The first rows, and how many more there are.
function top(rows: string[], n = 5): string[] {
  return rows.length > n ? [...rows.slice(0, n), `and ${rows.length - n} more`] : rows;
}

type ContextAnswer = SDKControlGetContextUsageResponse;

// Claude Code's /context grid: a full cell, a part-full one, free space, and
// the buffer that autocompact keeps.
function contextMark(kind: string | undefined, color: string, fullness = 1): ContextMark {
  const glyph = kind === "free" || kind === "deferred" ? "⛶" : kind === "buffer" ? "⛝" : fullness >= 0.7 ? "⛁" : "⛀";
  return { glyph, color };
}

function contextSections(c: ContextAnswer): UsageSection[] {
  const sections: UsageSection[] = [];
  const add = (title: string, lines: string[]) => {
    if (lines.length) sections.push({ title, lines });
  };
  const m = c.messageBreakdown;
  if (m) {
    add(
      "Messages",
      (
        [
          ["Tool calls", m.toolCallTokens],
          ["Tool results", m.toolResultTokens],
          ["Attachments", m.attachmentTokens],
          ["Claude's messages", m.assistantMessageTokens],
          ["Your messages", m.userMessageTokens],
        ] as const
      ).flatMap(([name, n]) => (n ? [`${name}: ${tokens(n)}`] : [])),
    );
  }
  const servers = new Map<string, { tools: number; tokens: number; loaded: boolean }>();
  for (const t of c.mcpTools) {
    const s = servers.get(t.serverName) ?? { tools: 0, tokens: 0, loaded: false };
    servers.set(t.serverName, { tools: s.tools + 1, tokens: s.tokens + t.tokens, loaded: s.loaded || t.isLoaded !== false });
  }
  add(
    "MCP tools",
    top(
      [...servers]
        .sort((a, b) => b[1].tokens - a[1].tokens)
        .map(([name, s]) => `${name}: ${s.tools} tool${s.tools === 1 ? "" : "s"}, ${tokens(s.tokens)}${s.loaded ? "" : " (deferred)"}`),
    ),
  );
  add("Custom agents", top([...c.agents].sort((a, b) => b.tokens - a.tokens).map((a) => `${a.agentType}: ${tokens(a.tokens)}`)));
  add(
    "Memory files",
    c.memoryFiles.map((f) => `${f.type}: ${tildePath(f.path)} (${tokens(f.tokens)})`),
  );
  const sk = c.skills;
  if (sk?.totalSkills) {
    const rows = [...sk.skillFrontmatter].sort((a, b) => b.tokens - a.tokens).map((s) => `${s.name}: ${tokens(s.tokens)}`);
    add("Skills", [`${sk.includedSkills} of ${sk.totalSkills} skills, ${tokens(sk.tokens)}`, ...top(rows)]);
  }
  return sections;
}

export function contextEvent(c: ContextAnswer): Event {
  const kinds = new Map(c.categories.map((cat) => [cat.name, cat.kind]));
  const share = (n: number) => ((n / c.maxTokens) * 100).toFixed(1);
  return {
    type: "context_usage",
    context: {
      title: `${c.model} · ${tokens(c.totalTokens)}/${tokens(c.maxTokens)} tokens (${Math.round(c.percentage)}%)`,
      grid: c.gridRows.map((row) => row.map((cell) => contextMark(kinds.get(cell.categoryName), cell.color, cell.squareFullness))),
      legend: c.categories
        .filter((cat) => cat.tokens > 0)
        .map((cat) => ({
          ...contextMark(cat.kind, cat.color),
          text: `${cat.name}: ${tokens(cat.tokens)} tokens (${share(cat.tokens)}%)`,
          ...(cat.kind === "deferred" ? { dim: true } : {}),
        })),
      sections: contextSections(c),
    },
  };
}

function mcpServer(s: McpServerStatus): McpServer {
  const c = s.config as { type?: string; command?: string; args?: string[]; url?: string } | undefined;
  // A claude.ai connector's URL is Claude Code's proxy, which says nothing.
  const where = c?.command ? [c.command, ...(c.args ?? [])].join(" ") : c?.type !== "claudeai-proxy" ? c?.url : undefined;
  return {
    name: s.name,
    status: s.status,
    ...(s.source ?? s.scope ? { scope: s.source ?? s.scope } : {}),
    ...(where ? { where } : {}),
    ...(s.error ? { error: s.error } : {}),
    tools: (s.tools ?? []).map((t) => t.name),
    ...(isEditorTool(s.source ? { name: s.name, source: s.source } : undefined) ? { own: true } : {}),
  };
}

export function mcpEvent(servers: McpServerStatus[], error?: string): Event {
  return { type: "mcp_servers", servers: servers.map(mcpServer), ...(error ? { error } : {}) };
}

const MCP_STATUS: [McpServerStatus["status"], string][] = [
  ["connected", "connected"],
  ["needs-auth", "need auth"],
  ["failed", "failed"],
  ["pending", "pending"],
  ["disabled", "disabled"],
];

// How Claude Code logs in, as its Status tab names it.
function login(a: AccountInfo): string | undefined {
  if (a.subscriptionType) return `${a.subscriptionType} account`;
  if (a.apiKeySource && a.apiKeySource !== "none") return `API key (${a.apiKeySource})`;
  if (a.apiProvider && a.apiProvider !== "firstParty") return a.apiProvider;
  return undefined;
}

export function sessionInfoEvent(version: string | undefined, account: AccountInfo, servers: McpServerStatus[]): Event {
  const mcp = MCP_STATUS.flatMap(([status, words]) => {
    const n = servers.filter((s) => s.status === status).length;
    return n ? [`${n} ${words}`] : [];
  });
  return {
    type: "session_info",
    info: {
      version,
      login: login(account),
      organization: account.organization,
      email: account.email,
      mcp: mcp.join(" · ") || "none",
    },
  };
}

// The text of a slash command's output message, or undefined for other text.
export function commandOutput(content: string): string | undefined {
  const match = content.match(/^<local-command-(?:stdout|stderr)>([\s\S]*)<\/local-command-(?:stdout|stderr)>$/);
  return match ? match[1]!.trim() : undefined;
}

export function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b: AnyRecord) => b.type === "text")
    .map((b: AnyRecord) => b.text)
    .join("\n");
}

// The first `end` characters, without a lone half of a UTF-16 surrogate pair.
// JSON would send it as an escape that Neovim's decoder refuses.
function head(s: string, end: number): string {
  const code = s.charCodeAt(end - 1);
  return s.slice(0, code >= 0xd800 && code <= 0xdbff ? end - 1 : end);
}

export function truncate(s: string, max = MAX_TEXT): string {
  return s.length > max ? head(s, max) + "..." : s;
}

// A Read's text numbers its lines. Saved sessions and subagents' results have
// no tool_use_result, so the line count comes from there.
export function readResult(text: string): { file: { numLines: number } } | undefined {
  const lines = text.split("\n").filter((line) => /^\s*\d+\t/.test(line)).length;
  return lines > 0 ? { file: { numLines: lines } } : undefined;
}

// A slash command's output ends at a line end, so no table row breaks.
export function truncateOutput(s: string): string {
  if (s.length <= MAX_OUTPUT) return s;
  const end = s.lastIndexOf("\n", MAX_OUTPUT);
  return (end > 0 ? s.slice(0, end) : head(s, MAX_OUTPUT)) + "\n...";
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
