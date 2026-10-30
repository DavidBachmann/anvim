// The answers to the plugin's dialog requests: the models, /usage, /context,
// /mcp, /status and /rewind, each from one of Claude Code's control requests.
import type {
  AccountInfo,
  McpServerStatus,
  ModelInfo,
  RewindFilesResult,
  SDKControlGetContextUsageResponse,
  SDKControlGetUsageResponse,
} from "@anthropic-ai/claude-agent-sdk";
import type { ContextMark, Event, McpServer, UsageSection } from "./protocol";
import { tildePath } from "./sandbox";
import { isOwnServer } from "./tools";

export function modelsEvent(models: ModelInfo[]): Event {
  return {
    type: "models",
    models: models.map((m) => ({
      value: m.value,
      name: m.displayName,
      description: m.description,
      resolved: m.resolvedModel,
      effort_levels: m.supportsEffort && m.supportedEffortLevels?.length ? m.supportedEffortLevels : undefined,
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
  const ranked = (label: string, rows: { name: string; pct: number }[]) =>
    rows.length ? [`Top ${label}: ${rows.map((r) => `${r.name} ${r.pct}%`).join(", ")}`] : [];
  return {
    title: `${title} · ${w.request_count} requests · ${w.session_count} sessions`,
    lines: [
      ...w.behaviors.flatMap((b) => (BEHAVIORS[b.key] ? [`${b.pct}% of your usage ${BEHAVIORS[b.key]}`] : [])),
      ...ranked("subagents", w.agents),
      ...ranked("skills", w.skills),
      ...ranked("plugins", w.plugins),
      ...ranked("MCP servers", w.mcp_servers),
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
    return [{ title, percent: limit.utilization, resets_at: Number.isFinite(resets) ? Math.floor(resets) : undefined }];
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
          dim: cat.kind === "deferred" || undefined,
        })),
      sections: contextSections(c),
    },
  };
}

function mcpServer(s: McpServerStatus): McpServer {
  const c = s.config as { type?: string; command?: string; args?: string[]; url?: string } | undefined;
  return {
    name: s.name,
    status: s.status,
    scope: s.source ?? s.scope,
    // A claude.ai connector's URL is Claude Code's proxy, which says nothing.
    where: c?.command ? [c.command, ...(c.args ?? [])].join(" ") : c?.type !== "claudeai-proxy" ? c?.url : undefined,
    error: s.error || undefined,
    tools: (s.tools ?? []).map((t) => t.name),
    own: isOwnServer(s) || undefined,
  };
}

export function mcpEvent(servers: McpServerStatus[], error?: string): Event {
  return { type: "mcp_servers", servers: servers.map(mcpServer), error };
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

export function rewindFilesEvent(uuid: string, dryRun: boolean, r: RewindFilesResult): Event {
  return {
    type: "rewind_files",
    uuid,
    dry_run: dryRun,
    can_rewind: r.canRewind,
    error: r.error,
    files: r.filesChanged,
    insertions: r.insertions,
    deletions: r.deletions,
    skipped: r.skippedLinks || undefined,
  };
}
