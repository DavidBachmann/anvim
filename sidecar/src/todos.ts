// anvim's todo list: one JSON file per project, which every anvim in the
// project shares. Each change takes a lock, and a watch on the file's dir
// sends the changes of other anvims on.
import type { HookCallback, SessionStartHookInput } from "@anthropic-ai/claude-agent-sdk";
import {
  type FSWatcher,
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import type { Event, TodoItem, TodoStatus } from "./protocol";

export type StoredTodo = TodoItem & { created: number; updated: number };
export type TodoFile = { next_id: number; items: StoredTodo[] };

export type NewTodo = {
  subject: string;
  description?: string;
  active_form?: string;
  owner?: string;
  blocked_by?: number[];
};

export type TodoUpdate = {
  id: number;
  status?: TodoStatus | "deleted";
  subject?: string;
  description?: string;
  active_form?: string;
  owner?: string | null;
  blocked_by?: number[];
};

// A mistake in the model's call. The tool returns it as an error.
export class TodoError extends Error {}

const STATUSES: TodoStatus[] = ["pending", "in_progress", "completed"];
// A lock that lives longer than this belongs to an anvim that died.
export const STALE_LOCK_MS = 5_000;

// A missing or broken file is an empty list.
export function parse(text: string | undefined): TodoFile {
  let data: unknown;
  try {
    data = text ? JSON.parse(text) : undefined;
  } catch {
    data = undefined;
  }
  const raw = data as { next_id?: unknown; items?: unknown } | undefined;
  const items: StoredTodo[] = [];
  for (const it of Array.isArray(raw?.items) ? raw.items : []) {
    const i = it as Partial<StoredTodo>;
    const valid = Number.isInteger(i.id) && typeof i.subject === "string" && STATUSES.includes(i.status as TodoStatus);
    if (!valid) continue;
    if (items.some((other) => other.id === i.id)) continue;
    items.push({
      id: i.id!,
      subject: i.subject as string,
      status: i.status!,
      ...(typeof i.description === "string" && i.description !== "" ? { description: i.description } : {}),
      ...(typeof i.active_form === "string" && i.active_form !== "" ? { active_form: i.active_form } : {}),
      ...(typeof i.owner === "string" && i.owner !== "" ? { owner: i.owner } : {}),
      ...(Array.isArray(i.blocked_by) && i.blocked_by.length > 0
        ? { blocked_by: i.blocked_by.filter((n) => Number.isInteger(n)) }
        : {}),
      created: typeof i.created === "number" ? i.created : 0,
      updated: typeof i.updated === "number" ? i.updated : 0,
    });
  }
  const top = items.reduce((max, i) => Math.max(max, i.id), 0);
  const next = typeof raw?.next_id === "number" && Number.isInteger(raw.next_id) ? raw.next_id : 1;
  return { next_id: Math.max(next, top + 1), items };
}

// The list as the protocol sends it, without the times.
export function plain(file: TodoFile): TodoItem[] {
  return file.items.map(({ created: _c, updated: _u, ...item }) => item);
}

const open = (item: TodoItem) => item.status !== "completed";

// The blockers that are not done yet.
function blockers(item: TodoItem, items: TodoItem[]): number[] {
  return (item.blocked_by ?? []).filter((id) => items.some((other) => other.id === id && open(other)));
}

function line(item: TodoItem, items: TodoItem[]): string {
  const owner = item.owner ? ` (owner: ${item.owner})` : "";
  const blocked = open(item) ? blockers(item, items) : [];
  const by = blocked.length > 0 ? ` (blocked by ${blocked.map((id) => `#${id}`).join(", ")})` : "";
  return `#${item.id} [${item.status}] ${item.subject}${owner}${by}`;
}

// The list for the model: a line per item, and under each open item its description.
export function listText(items: TodoItem[]): string {
  if (items.length === 0) return "The todo list is empty.";
  const lines: string[] = [];
  for (const item of items) {
    lines.push(line(item, items));
    if (open(item) && item.description) lines.push(...item.description.split("\n").map((l) => `    ${l}`));
  }
  return lines.join("\n");
}

// What a new session learns about the list: its open items.
export function openText(items: TodoItem[]): string | undefined {
  const rest = items.filter(open);
  if (rest.length === 0) return undefined;
  return [
    "anvim's todo list for this project has open items:",
    ...rest.map((item) => line(item, items)),
    "Call todo_list for the whole list with the descriptions.",
  ].join("\n");
}

function subject(s: string | undefined): string {
  const t = s?.trim() ?? "";
  if (t === "") throw new TodoError("The subject must not be empty.");
  return t;
}

function checkBlockers(ids: number[] | undefined, items: TodoItem[], self?: number): number[] | undefined {
  if (!ids || ids.length === 0) return undefined;
  for (const id of ids) {
    if (id === self) throw new TodoError(`Item #${id} cannot block itself.`);
    if (!items.some((item) => item.id === id)) throw new TodoError(`There is no item #${id} to block on.`);
  }
  return [...new Set(ids)];
}

// Sets an optional text field: an empty text removes it.
function setText(item: StoredTodo, key: "description" | "active_form" | "owner", value: string | null | undefined) {
  if (value === undefined) return;
  if (value === null || value.trim() === "") delete item[key];
  else item[key] = value;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function readText(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

// A rename replaces the file whole, so no reader sees half of it.
function writeFile(path: string, text: string): void {
  const tmp = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

const serialize = (file: TodoFile) => JSON.stringify(file, null, 2) + "\n";

export class TodoStore {
  private last: string | undefined;
  private watcher: FSWatcher | undefined;

  constructor(
    readonly path: string,
    private emit: (ev: Event) => void,
  ) {}

  // Creates the dir, sends the list and watches for other anvims' changes.
  // A rename replaces the file, so the watch is on the dir.
  // A dir that anvim cannot write costs the list, not the session.
  start(): void {
    this.sync();
    const name = basename(this.path);
    try {
      mkdirSync(dirname(this.path), { recursive: true });
      this.watcher = watch(dirname(this.path), (_event, file) => {
        if (file == null || file === name) this.sync();
      });
      this.watcher.unref?.();
    } catch (err) {
      process.stderr.write(`could not watch ${dirname(this.path)}: ${err}\n`);
    }
  }

  close(): void {
    this.watcher?.close();
    this.watcher = undefined;
  }

  // The list that the last /reset replaced.
  get prevPath(): string {
    return this.path.replace(/(\.json)?$/, ".prev.json");
  }

  read(): TodoFile {
    return parse(readText(this.path));
  }

  items(): TodoItem[] {
    return plain(this.read());
  }

  // Sends the list when it differs from the last one sent.
  sync(items = this.items()): void {
    const json = JSON.stringify(items);
    if (json === this.last) return;
    this.last = json;
    this.emit({ type: "todos", items });
  }

  async add(inputs: NewTodo[]): Promise<{ ids: number[]; items: TodoItem[] }> {
    if (inputs.length === 0) throw new TodoError("Give at least one item.");
    return this.change((file) => {
      const now = Date.now();
      const ids: number[] = [];
      for (const input of inputs) {
        const item: StoredTodo = {
          id: file.next_id,
          subject: subject(input.subject),
          status: "pending",
          created: now,
          updated: now,
        };
        setText(item, "description", input.description);
        setText(item, "active_form", input.active_form);
        setText(item, "owner", input.owner);
        const blocked = checkBlockers(input.blocked_by, file.items);
        if (blocked) item.blocked_by = blocked;
        file.items.push(item);
        file.next_id++;
        ids.push(item.id);
      }
      return ids;
    }).then(({ result, items }) => ({ ids: result, items }));
  }

  async update(input: TodoUpdate): Promise<TodoItem[]> {
    const { items } = await this.change((file) => {
      const item = file.items.find((i) => i.id === input.id);
      if (!item) throw new TodoError(`There is no item #${input.id}.`);
      if (input.status === "deleted") {
        file.items = file.items.filter((i) => i !== item);
        for (const other of file.items) {
          if (!other.blocked_by?.includes(item.id)) continue;
          other.blocked_by = other.blocked_by.filter((id) => id !== item.id);
          if (other.blocked_by.length === 0) delete other.blocked_by;
        }
        return;
      }
      if (input.subject !== undefined) item.subject = subject(input.subject);
      if (input.status) item.status = input.status;
      setText(item, "description", input.description);
      setText(item, "active_form", input.active_form);
      setText(item, "owner", input.owner);
      if (input.blocked_by !== undefined) {
        const blocked = checkBlockers(input.blocked_by, file.items, item.id);
        if (blocked) item.blocked_by = blocked;
        else delete item.blocked_by;
      }
      item.updated = Date.now();
    });
    return items;
  }

  // /reset: the list becomes the previous list, and ids start at 1 again. An
  // empty list leaves the previous list alone, so a second /reset loses nothing.
  async reset(): Promise<void> {
    try {
      await this.locked(() => {
        if (this.read().items.length > 0) renameSync(this.path, this.prevPath);
        else rmSync(this.path, { force: true });
      });
    } finally {
      this.resend();
    }
  }

  // /undo-reset: swaps the list and the previous list, so a second undo swaps
  // them back. False when there is no previous list.
  async undo(): Promise<boolean> {
    const swapped = await this.locked(() => {
      const prev = readText(this.prevPath);
      if (prev === undefined) return false;
      const current = readText(this.path) ?? serialize(parse(undefined));
      writeFile(this.path, prev);
      writeFile(this.prevPath, current);
      return true;
    });
    if (swapped) {
      this.resend();
      // Claude learns the list that came back with the next prompt.
      this.told = false;
    }
    return swapped;
  }

  // The plugin empties its list ahead of a /reset, so the answer goes out
  // also when the list did not change.
  private resend(): void {
    this.last = undefined;
    this.sync();
  }

  // Reads, changes and writes the file under the lock. A change that throws
  // writes nothing.
  private async change<T>(fn: (file: TodoFile) => T): Promise<{ result: T; items: TodoItem[] }> {
    const { result, items } = await this.locked(() => {
      const file = this.read();
      const result = fn(file);
      writeFile(this.path, serialize(file));
      return { result, items: plain(file) };
    });
    this.sync(items);
    return { result, items };
  }

  private async locked<T>(fn: () => T): Promise<T> {
    await this.lock();
    try {
      return fn();
    } finally {
      this.unlock();
    }
  }

  private get lockPath(): string {
    return `${this.path}.lock`;
  }

  private async lock(): Promise<void> {
    mkdirSync(dirname(this.path), { recursive: true });
    while (true) {
      try {
        closeSync(openSync(this.lockPath, "wx"));
        return;
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      }
      const stat = statSync(this.lockPath, { throwIfNoEntry: false });
      if (stat && Date.now() - stat.mtimeMs > STALE_LOCK_MS) {
        try {
          unlinkSync(this.lockPath);
        } catch (err) {
          // ENOENT: another anvim took the stale lock away first.
          if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
        }
        continue;
      }
      await sleep(10);
    }
  }

  private unlock(): void {
    try {
      unlinkSync(this.lockPath);
    } catch {
      // The lock went stale, and another anvim took it away.
    }
  }

  // Tells a session that compacts what is still open. After a clear, the next
  // prompt tells: Claude Code runs this hook just after conversation_reset,
  // before a /reset can delete the list.
  sessionStart: HookCallback = async (input) => {
    const { hook_event_name, source } = input as SessionStartHookInput;
    this.told = source !== "clear";
    if (!this.told) return {};
    const context = hook_event_name === "SessionStart" ? openText(this.items()) : undefined;
    if (!context) return {};
    return { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: context } };
  };

  // Claude Code 2.1.304 runs an SDK's SessionStart hook for clear and compact,
  // but not for startup or resume. So the first prompt tells those, and the
  // first prompt after a clear.
  private told = false;
  firstPrompt: HookCallback = async () => {
    if (this.told) return {};
    this.told = true;
    const context = openText(this.items());
    if (!context) return {};
    return { hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: context } };
  };
}
