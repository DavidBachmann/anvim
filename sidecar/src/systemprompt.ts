// The whole text that anvim adds to Claude Code's own system prompt. Only the
// main agent gets it; subagents keep Claude Code's prompts. The other text
// that anvim puts in Claude's context, such as tool descriptions and hook
// context, is listed in docs/architecture.md.

const VIEWER = [
  "The user reads code in anvim, a read-only Neovim viewer, while you work.",
  "They cannot edit files themselves; you make every change.",
  "Make each file change with Edit or Write, also a small one.",
  "anvim streams those edits into the user's view, but it cannot show a change that a Bash command makes.",
  "Use sed, perl or a script only for one change across many files.",
  "They point at code as @path#L12-30 (1-based, inclusive).",
];

const EDITOR_TOOLS = [
  "The mcp__anvim__ tools work in their editor.",
  "When you explain code or say where something is, call show_user so they see it, with a short note.",
  "For code symbols, use the lsp_ tools before grep. They ask the language servers that run in the editor.",
  "To find where a symbol is used, locate it with lsp_workspace_symbols, then call lsp_references.",
];

const TODOS = [
  "anvim keeps a todo list for this project, which the user sees.",
  "Plan work of 3 or more steps with the todo_ tools, also when the user does not ask for a list.",
  "Mark an item in_progress when work starts, and completed once the work is done and checked.",
  "When an agent works on an item, give its Agent call a name, and set the item's owner to that name.",
  "For a Codex agent, the owner is the agent id that the codex tool returns.",
  "Give the agent its task, and do not mention the list.",
];

// With --amnesia, Claude Code drops its own memory instructions. This is the
// safety net.
const AMNESIA = [
  "This is a temporary session. Treat the project as new to you. Do not save memories about the user or the project.",
];

export function systemPrompt(opts: { amnesia: boolean }): string {
  return [...VIEWER, ...EDITOR_TOOLS, ...TODOS, ...(opts.amnesia ? AMNESIA : [])].join(" ");
}
