import { afterAll, describe, expect, test } from "bun:test";
import type { HookInput } from "@anthropic-ai/claude-agent-sdk";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { existsSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Event } from "./protocol";
import { TodoStore } from "./todos";
import { EditorBridge, editorServer, isEditorTool, SERVER, TODO_TOOLS } from "./tools";

const root = mkdtempSync(join(tmpdir(), "anvim-todos-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
const signal = new AbortController().signal;
let n = 0;

function store(path = join(root, `p${++n}`, "todos.json")) {
  const events: Extract<Event, { type: "todos" }>[] = [];
  const s = new TodoStore(path, (ev) => events.push(ev as Extract<Event, { type: "todos" }>));
  return { s, events, path };
}

const subjects = (items: { id: number; subject: string; status: string }[]) =>
  items.map((i) => `#${i.id} ${i.status} ${i.subject}`);

describe("the todo store", () => {
  test("adds, updates and deletes items, and never uses an id again", async () => {
    const { s, events, path } = store();
    s.start();
    // A missing file is an empty list, and the start sends it.
    expect(events).toEqual([{ type: "todos", items: [] }]);
    const { ids } = await s.add([
      { subject: " Read the parser " },
      { subject: "Fix it", owner: "fixer", blocked_by: [1] },
    ]);
    expect(ids).toEqual([1, 2]);
    await s.update({ id: 1, status: "in_progress", active_form: "Reading the parser" });
    await s.update({ id: 2, owner: null });
    await s.update({ id: 2, status: "deleted" });
    const { ids: next } = await s.add([{ subject: "Test it", description: "Run bun test." }]);
    expect(next).toEqual([3]);
    expect(s.items()).toEqual([
      { id: 1, subject: "Read the parser", status: "in_progress", active_form: "Reading the parser" },
      { id: 3, subject: "Test it", description: "Run bun test.", status: "pending" },
    ]);
    expect(events.at(-1)!.items).toEqual(s.items());
    expect(events.map((e) => subjects(e.items).join(", "))).toEqual([
      "",
      "#1 pending Read the parser, #2 pending Fix it",
      "#1 in_progress Read the parser, #2 pending Fix it",
      "#1 in_progress Read the parser, #2 pending Fix it",
      "#1 in_progress Read the parser",
      "#1 in_progress Read the parser, #3 pending Test it",
    ]);
    expect(events[3]!.items[1]!.owner).toBeUndefined();
    const file = JSON.parse(readFileSync(path, "utf8"));
    expect(file.next_id).toBe(4);
    expect(typeof file.items[0].created).toBe("number");
    // The lock is gone after each change.
    expect(existsSync(`${path}.lock`)).toBe(false);
    s.close();
  });

  test("a wrong id, an empty subject or an unknown blocker changes nothing", async () => {
    const { s } = store();
    await s.add([{ subject: "One" }]);
    await expect(s.update({ id: 7, status: "completed" })).rejects.toThrow("There is no item #7.");
    await expect(s.update({ id: 1, subject: "  " })).rejects.toThrow("The subject must not be empty.");
    await expect(s.add([{ subject: "Two" }, { subject: "" }])).rejects.toThrow("The subject must not be empty.");
    await expect(s.update({ id: 1, blocked_by: [1] })).rejects.toThrow("cannot block itself");
    expect(subjects(s.items())).toEqual(["#1 pending One"]);
  });

  test("a broken file is an empty list, and a stale lock does not block a change", async () => {
    const { s, path } = store();
    s.start();
    writeFileSync(path, "{ not json");
    expect(s.items()).toEqual([]);
    writeFileSync(`${path}.lock`, "");
    const old = (Date.now() - 6_000) / 1000;
    utimesSync(`${path}.lock`, old, old);
    await s.add([{ subject: "After the stale lock" }]);
    expect(subjects(s.items())).toEqual(["#1 pending After the stale lock"]);
    s.close();
  });

  test("another anvim's change reaches this store's events", async () => {
    const first = store();
    const second = store(first.path);
    first.s.start();
    second.s.start();
    // The watch starts to listen a moment after start(), later under load.
    await Bun.sleep(200);
    await second.s.add([{ subject: "From the other anvim" }]);
    for (let i = 0; i < 500 && first.events.length < 2; i++) await Bun.sleep(10);
    expect(first.events.map((e) => subjects(e.items))).toEqual([[], ["#1 pending From the other anvim"]]);
    // The store's own change after it sends one event, not a second from the watch.
    await first.s.update({ id: 1, status: "completed" });
    await Bun.sleep(100);
    expect(first.events.length).toBe(3);
    first.s.close();
    second.s.close();
  });

  test("/reset keeps the list as the previous list, and /undo-reset swaps the two", async () => {
    const { s, events, path } = store();
    s.start();
    await s.add([{ subject: "Old one" }, { subject: "Old two" }]);
    await s.reset();
    expect(s.items()).toEqual([]);
    expect(existsSync(path)).toBe(false);
    expect(JSON.parse(readFileSync(s.prevPath, "utf8")).items.length).toBe(2);
    // Ids start again at 1.
    expect((await s.add([{ subject: "New one" }])).ids).toEqual([1]);
    expect(await s.undo()).toBe(true);
    expect(subjects(s.items())).toEqual(["#1 pending Old one", "#2 pending Old two"]);
    expect(await s.undo()).toBe(true);
    expect(subjects(s.items())).toEqual(["#1 pending New one"]);
    // A reset of an empty list keeps the previous list.
    await s.update({ id: 1, status: "deleted" });
    await s.reset();
    expect(await s.undo()).toBe(true);
    expect(subjects(s.items())).toEqual(["#1 pending Old one", "#2 pending Old two"]);
    // Each reset and swap sends one event, and the watch adds none.
    await Bun.sleep(100);
    expect(events.map((e) => subjects(e.items).join(", "))).toEqual([
      "",
      "#1 pending Old one, #2 pending Old two",
      "",
      "#1 pending New one",
      "#1 pending Old one, #2 pending Old two",
      "#1 pending New one",
      "",
      "",
      "#1 pending Old one, #2 pending Old two",
    ]);
    s.close();
  });

  test("/undo-reset without a previous list changes nothing", async () => {
    const { s, events } = store();
    s.start();
    await s.add([{ subject: "Kept" }]);
    expect(await s.undo()).toBe(false);
    expect(subjects(s.items())).toEqual(["#1 pending Kept"]);
    expect(events.length).toBe(2);
    s.close();
  });

  test("another anvim sees a reset and an undo", async () => {
    const first = store();
    const second = store(first.path);
    first.s.start();
    second.s.start();
    const last = () => subjects(first.events.at(-1)!.items).join(", ");
    const until = async (text: string) => {
      for (let i = 0; i < 500 && last() !== text; i++) await Bun.sleep(10);
      expect(last()).toBe(text);
    };
    await Bun.sleep(200);
    await second.s.add([{ subject: "Shared" }]);
    await until("#1 pending Shared");
    await second.s.reset();
    await until("");
    await second.s.undo();
    await until("#1 pending Shared");
    first.s.close();
    second.s.close();
  });

  test("a new session learns the open items", async () => {
    const { s } = store();
    const context = async () =>
      s.sessionStart({ hook_event_name: "SessionStart", source: "compact" } as HookInput, undefined, { signal });
    expect(await context()).toEqual({});
    await s.add([{ subject: "Done one" }, { subject: "Open one", owner: "explorer" }]);
    await s.update({ id: 1, status: "completed" });
    expect(await context()).toEqual({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: [
          "anvim's todo list for this project has open items:",
          "#2 [pending] Open one (owner: explorer)",
          "Call todo_list for the whole list with the descriptions.",
        ].join("\n"),
      },
    });
    await s.update({ id: 2, status: "completed" });
    expect(await context()).toEqual({});
  });

  test("the first prompt tells a start or a resume, which get no SessionStart hook", async () => {
    const { s } = store();
    await s.add([{ subject: "Open one" }]);
    const prompt = () => s.firstPrompt({ hook_event_name: "UserPromptSubmit" } as HookInput, undefined, { signal });
    const first = (await prompt()) as { hookSpecificOutput: { hookEventName: string; additionalContext: string } };
    expect(first.hookSpecificOutput.hookEventName).toBe("UserPromptSubmit");
    expect(first.hookSpecificOutput.additionalContext).toContain("#1 [pending] Open one");
    expect(await prompt()).toEqual({});
    // A clear's hook tells nothing, because a /reset may delete the list next.
    // The next prompt tells.
    const clear = { hook_event_name: "SessionStart", source: "clear" } as HookInput;
    expect(await s.sessionStart(clear, undefined, { signal })).toEqual({});
    expect(JSON.stringify(await prompt())).toContain("#1 [pending] Open one");
  });
});

describe("the todo tools", () => {
  async function connect(s?: TodoStore) {
    const server = editorServer(new EditorBridge(() => {}), s ? { todos: s } : {});
    const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
    await server.instance.connect(serverSide);
    const client = new Client({ name: "test", version: "0" });
    await client.connect(clientSide);
    return client;
  }
  const textOf = (res: Awaited<ReturnType<Client["callTool"]>>) => (res.content as { text: string }[])[0]!.text;

  test("need no permission prompt", () => {
    for (const tool of TODO_TOOLS) expect(isEditorTool({ name: SERVER, source: "sdk" }, tool)).toBe(true);
  });

  test("exist only with a store, and return the whole list", async () => {
    const without = (await (await connect()).listTools()).tools.map((t) => t.name);
    expect(without.filter((name) => name.startsWith("todo_"))).toEqual([]);
    const { s } = store();
    const client = await connect(s);
    const names = (await client.listTools()).tools.map((t) => t.name);
    expect(names).toEqual(expect.arrayContaining(["todo_add", "todo_update", "todo_list"]));
    const added = await client.callTool({
      name: "todo_add",
      arguments: {
        items: [
          { subject: "Read the parser", description: "Find where it breaks.\nNote the line." },
          { subject: "Fix it", blocked_by: [1] },
        ],
      },
    });
    expect(textOf(added)).toBe(
      [
        "Added #1, #2.",
        "",
        "#1 [pending] Read the parser",
        "    Find where it breaks.",
        "    Note the line.",
        "#2 [pending] Fix it (blocked by #1)",
      ].join("\n"),
    );
    await client.callTool({ name: "todo_update", arguments: { id: 1, status: "completed" } });
    const listed = await client.callTool({ name: "todo_list", arguments: {} });
    expect(textOf(listed)).toBe(["#1 [completed] Read the parser", "#2 [pending] Fix it"].join("\n"));
    const wrong = await client.callTool({ name: "todo_update", arguments: { id: 9, status: "completed" } });
    expect([wrong.isError, textOf(wrong)]).toEqual([true, "There is no item #9."]);
    const empty = await client.callTool({ name: "todo_add", arguments: { items: [{ subject: "" }] } });
    expect([empty.isError, textOf(empty)]).toEqual([true, "The subject must not be empty."]);
  });
});
