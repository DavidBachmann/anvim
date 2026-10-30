import { describe, expect, test } from "bun:test";
import { commandParts, excludedCommand } from "./shell";

describe("excluded commands", () => {
  test("ask when a command word of the line is an entry's first word", () => {
    expect(excludedCommand("touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("npm run build", ["npm run:*"])).toBe(true);
    expect(excludedCommand("make", ["make"])).toBe(true);
    // Claude Code keeps these in the sandbox. anvim asks anyway, because it
    // cannot follow every form that Claude Code's parser takes.
    expect(excludedCommand("make all", ["make"])).toBe(true);
    expect(excludedCommand("touch ~/x && echo WROTE || echo BLOCKED", ["touch *"])).toBe(true);
    expect(excludedCommand("cat a | touch b", ["touch *"])).toBe(true);
    // Other command words, and the same word as an argument, do not ask.
    expect(excludedCommand("ls touch", ["touch *"])).toBe(false);
    expect(excludedCommand("touchy x", ["touch *"])).toBe(false);
    expect(excludedCommand("echo 'touch x; rm y'", ["touch *", "rm *"])).toBe(false);
    expect(excludedCommand("touch x", [])).toBe(false);
  });

  test("ask for the lines that ran outside the sandbox in bypass mode", () => {
    // With touch * in a project's settings, each of these ran outside the sandbox.
    expect(excludedCommand("CI=1; touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("gtimeout 5 touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("touch\t~/x", ["touch *"])).toBe(true);
  });

  test("see through quotes, VAR=value words, wrappers and their options", () => {
    expect(excludedCommand("'touch' x", ["touch *"])).toBe(true);
    expect(excludedCommand('t"ouch" x', ["touch *"])).toBe(true);
    expect(excludedCommand("\\touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("CI=1 FOO='a b' make", ["make"])).toBe(true);
    expect(excludedCommand("timeout -s KILL 5 touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("env -u HOME nice -n 5 make 2>&1", ["make"])).toBe(true);
    expect(excludedCommand("/usr/bin/touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("if true; then touch x; fi", ["touch *"])).toBe(true);
    expect(excludedCommand("echo $(touch x)", ["touch *"])).toBe(true);
    expect(excludedCommand('echo "`touch x`"', ["touch *"])).toBe(true);
    expect(excludedCommand("(cd a && touch x)", ["touch *"])).toBe(true);
  });

  test("match an entry's words before its first star, from where a command starts", () => {
    expect(excludedCommand("npm run build", ["npm run *"])).toBe(true);
    expect(excludedCommand("npm run", ["npm run *"])).toBe(true);
    expect(excludedCommand("npm test", ["npm run *"])).toBe(false);
    expect(excludedCommand("npm install", ["npm run:*"])).toBe(false);
    expect(excludedCommand("timeout 5 npm run build", ["npm run *"])).toBe(true);
    expect(excludedCommand("echo npm run x", ["npm run *"])).toBe(false);
    // A star inside a word makes that word a prefix.
    expect(excludedCommand("npm run-script x", ["npm run*"])).toBe(true);
    expect(excludedCommand("npm test", ["npm run*"])).toBe(false);
    // Claude Code keeps this line in the sandbox, because grep matches no entry.
    expect(excludedCommand("docker ps | grep x", ["docker *"])).toBe(true);
  });

  test("an entry with a star in its first word asks for every command", () => {
    expect(excludedCommand("ls", ["*"])).toBe(true);
    expect(excludedCommand("rm -rf x", ["* -rf *"])).toBe(true);
    expect(excludedCommand("docker-compose up", ["docker* up"])).toBe(true);
    expect(excludedCommand("podman run", ["docker* up"])).toBe(true);
  });

  test("split a line at its commands", () => {
    expect(commandParts("echo 'a && b' | wc -l; ls\nfalse || true &")).toEqual([
      "echo 'a && b'",
      "wc -l",
      "ls",
      "false",
      "true",
    ]);
    expect(commandParts('echo "a; \\" b"')).toEqual(['echo "a; \\" b"']);
    expect(commandParts("make 2>&1 &> log")).toEqual(["make 2>&1 &> log"]);
    expect(commandParts("a $(b) `c`")).toEqual(["a", "b", "c"]);
  });
});
