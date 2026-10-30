// Text from Claude Code's messages, and the limits on the text that goes to
// the plugin.

export type AnyRecord = Record<string, any>;

const MAX_TEXT = 2000;
// A subagent's reply can be long.
export const MAX_AGENT_TEXT = 8000;
// A local command such as /context prints about 10k characters of tables.
const MAX_OUTPUT = 20000;

export function errorText(err: unknown): string {
  return String((err as Error)?.message ?? err);
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
export function head(s: string, end: number): string {
  const code = s.charCodeAt(end - 1);
  return s.slice(0, code >= 0xd800 && code <= 0xdbff ? end - 1 : end);
}

// The last `n` characters, without a lone half of a surrogate pair, as head().
export function tail(s: string, n: number): string {
  if (s.length <= n) return s;
  const code = s.charCodeAt(s.length - n);
  return s.slice(code >= 0xdc00 && code <= 0xdfff ? s.length - n + 1 : s.length - n);
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
