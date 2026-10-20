// Editor context for prompts: what the code window showed when the user sent
// one. A UserPromptSubmit hook adds it to its prompt, in the words that Claude
// Code uses for its IDE integrations, so Claude reads it the same way.
import type { HookCallback } from "@anthropic-ai/claude-agent-sdk";
import { isAbsolute, resolve } from "node:path";
import type { PromptContext } from "./protocol";

// Claude Code cuts an IDE selection at this many characters.
const MAX_SELECTION = 2000;
// Prompts that never reach the hook must not pile up.
const MAX_PENDING = 20;
const MAYBE = "This may or may not be related to the current task.";

function clip(text: string): string {
  const chars = Array.from(text);
  return chars.length > MAX_SELECTION ? chars.slice(0, MAX_SELECTION).join("") + "\n... (truncated)" : text;
}

export function contextText(ctx: PromptContext, cwd: string): string {
  if (!ctx.file) return "";
  const path = isAbsolute(ctx.file) ? ctx.file : resolve(cwd, ctx.file);
  const sel = ctx.selection;
  if (sel) {
    return `The user selected the lines ${sel.start_line} to ${sel.end_line} from ${path}:\n${clip(sel.text)}\n${MAYBE}`;
  }
  const lines = [`The user opened the file ${path} in the IDE. ${MAYBE}`];
  const where = [];
  if (ctx.cursor_line) where.push(`The cursor is on line ${ctx.cursor_line}`);
  if (ctx.visible) where.push(`lines ${ctx.visible[0]} to ${ctx.visible[1]} are visible`);
  if (where.length) lines.push(where.join(", and ") + ".");
  return lines.join("\n");
}

// Contexts of the prompts that Claude Code has not taken yet. The hook gets
// the prompt's text, so it finds the context by text. A prompt that never
// reaches the hook, such as a local slash command, then shifts no other
// prompt's context. Prompts with the same text take theirs in order.
//
// A prompt sent while a turn runs reaches the hook after that turn's result,
// so a turn's end must keep it. A turn that ran no hook was a local command,
// and its prompt and older ones never will: they go, so that a prompt sent
// again later cannot take their context.
export class PendingContexts {
  private queue: { text: string; context?: PromptContext; seq: number }[] = [];
  private seq = 0;
  // The newest prompt when the current turn started.
  private turnFrom = 0;
  private hooked = false;

  push(text: string, context?: PromptContext): void {
    this.queue.push({ text, context, seq: ++this.seq });
    if (this.queue.length > MAX_PENDING) this.queue.shift();
  }

  take(prompt: string): PromptContext | undefined {
    this.hooked = true;
    const at = this.queue.findIndex((p) => p.text === prompt);
    if (at === -1) return undefined;
    // Earlier prompts went past the hook unseen.
    return this.queue.splice(0, at + 1)[at]!.context;
  }

  // The first message of a turn.
  turnStart(): void {
    this.turnFrom = this.seq;
  }

  // A turn's result.
  turnEnd(): void {
    if (!this.hooked) this.queue = this.queue.filter((p) => p.seq > this.turnFrom);
    this.hooked = false;
  }

  get size(): number {
    return this.queue.length;
  }
}

export function contextHook(pending: PendingContexts): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== "UserPromptSubmit") return {};
    const ctx = pending.take(input.prompt);
    const text = ctx ? contextText(ctx, input.cwd) : "";
    if (!text) return {};
    return { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: text } };
  };
}
