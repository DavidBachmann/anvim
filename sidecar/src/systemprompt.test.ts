import { describe, expect, test } from "bun:test";
import { subagentContext, systemPrompt, usesZsh } from "./systemprompt";

describe("the zsh note", () => {
  const found = () => "/bin/zsh";
  const missing = () => null;

  test("follows Claude Code's pick of the shell", () => {
    expect(usesZsh({ SHELL: "/bin/zsh" }, missing)).toBe(true);
    expect(usesZsh({ SHELL: "/bin/bash" }, found)).toBe(false);
    expect(usesZsh({ CLAUDE_CODE_SHELL: "/opt/homebrew/bin/bash", SHELL: "/bin/zsh" }, found)).toBe(false);
    expect(usesZsh({ SHELL: "/usr/bin/fish" }, found)).toBe(true);
    expect(usesZsh({ SHELL: "/usr/bin/fish" }, missing)).toBe(false);
  });

  test("reaches the main agent and subagents, also without notes", () => {
    const note = "Your Bash tool runs zsh";
    expect(systemPrompt({ amnesia: false, zsh: true })).toContain(note);
    expect(systemPrompt({ amnesia: false, zsh: false })).not.toContain(note);
    expect(subagentContext({ amnesia: true, zsh: true })).toStartWith(note);
    expect(subagentContext({ amnesia: true, zsh: false })).toBe("");
  });
});
