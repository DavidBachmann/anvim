// anvim's todo lists: one JSON file per list in the project's todo dir.
// sessions.json maps each session to its list, so /clear, a fork or a
// resume keeps the list, and two anvims on other sessions keep apart. Each
// change takes the dir's lock, and a watch on the dir sends the changes of
// other anvims on.
import type { HookCallback, SessionStartHookInput } from "@anthropic-ai/claude-agent-sdk";
import { randomBytes } from "node:crypto";
import {
  type FSWatcher,
  closeSync,
  existsSync,
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
// prev: the list that the /reset before this list replaced.
export type TodoFile = { next_id: number; items: StoredTodo[]; prev?: string };
// Session id to list id.
type SessionMap = Record<string, string>;

// A list id names a file in the dir.
const LIST_ID = /^[\w-]+$/;

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
  const raw = data as { next_id?: unknown; items?: unknown; prev?: unknown } | undefined;
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
  const prev = typeof raw?.prev === "string" && LIST_ID.test(raw.prev) ? { prev: raw.prev } : {};
  return { next_id: Math.max(next, top + 1), items, ...prev };
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
    "anvim's todo list for this session has open items:",
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

const listPath = (dir: string, list: string) => join(dir, `${list}.json`);

function readSessions(dir: string): SessionMap {
  let data: unknown;
  try {
    data = JSON.parse(readText(join(dir, "sessions.json")) ?? "");
  } catch {
    return {};
  }
  if (typeof data !== "object" || data === null || Array.isArray(data)) return {};
  const map: SessionMap = {};
  for (const [session, list] of Object.entries(data)) {
    if (typeof list === "string" && LIST_ID.test(list)) map[session] = list;
  }
  return map;
}

const writeSessions = (dir: string, map: SessionMap) =>
  writeFile(join(dir, "sessions.json"), JSON.stringify(map, null, 2) + "\n");

// A new list id, such as 20261102-141503-a1b2: the local time and 4 random
// hex digits.
function newListId(dir: string): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  while (true) {
    const d = new Date();
    const day = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
    const time = `${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    const id = `${day}-${time}-${randomBytes(2).toString("hex")}`;
    if (!existsSync(listPath(dir, id))) return id;
  }
}

// The open items of each session's list, for the resume picker. A session
// without open items has no entry.
export function openCounts(dir: string): Record<string, number> {
  const counts: Record<string, number> = {};
  const lists = new Map<string, number>();
  for (const [session, list] of Object.entries(readSessions(dir))) {
    let n = lists.get(list);
    if (n === undefined) {
      n = parse(readText(listPath(dir, list))).items.filter(open).length;
      lists.set(list, n);
    }
    if (n > 0) counts[session] = n;
  }
  return counts;
}

export class TodoStore {
  private last: string | undefined;
  private watcher: FSWatcher | undefined;
  // The session of the last init, and its list. A new session has neither.
  private session: string | undefined;
  private list: string | undefined;
  // The ids of the /clear prompts that a /reset sent.
  private resets = new Set<string>();
  // An older anvim's project list, which a start without a session shows,
  // and the first init takes in.
  private legacy = false;

  constructor(
    readonly dir: string,
    private emit: (ev: Event) => void,
    resume?: string,
  ) {
    this.session = resume;
  }

  // Finds the session's list, takes in an older anvim's project list, sends
  // the list and watches for other anvims' changes. Without a session, the
  // project list stays where it is until the first init, so a start that
  // ends before it loses nothing. A rename replaces a file, so the watch is
  // on the dir. A dir that anvim cannot write costs the list, not the
  // session.
  async start(): Promise<void> {
    try {
      await this.locked(() => {
        const parent = dirname(this.dir);
        this.legacy = existsSync(join(parent, "todos.json")) || existsSync(join(parent, "todos.prev.json"));
        if (this.session) this.take(this.session);
      });
    } catch (err) {
      process.stderr.write(`could not read the todo lists in ${this.dir}: ${err}\n`);
    }
    this.sync();
    try {
      this.watcher = watch(this.dir, (_event, file) => {
        if (file == null || file === "sessions.json") this.adopt();
        if (file == null || (this.list && file === `${this.list}.json`)) this.sync();
      });
      this.watcher.unref?.();
    } catch (err) {
      process.stderr.write(`could not watch ${this.dir}: ${err}\n`);
    }
  }

  close(): void {
    this.watcher?.close();
    this.watcher = undefined;
  }

  // Under the lock: the session's own list, else the project list of an
  // older anvim, else the current list. A session without an entry gets one.
  private take(session: string): void {
    const own = readSessions(this.dir)[session];
    const adopted = this.legacy ? this.migrate() : undefined;
    this.legacy = false;
    this.list = own ?? adopted ?? this.list;
    if (!own && this.list) this.link(session, this.list);
  }

  // The project list of an older anvim, todos.json next to the dir, becomes
  // a list in the dir, and todos.prev.json becomes its prev. Another anvim
  // may have taken it first.
  private migrate(): string | undefined {
    const parent = dirname(this.dir);
    const current = readText(join(parent, "todos.json"));
    const previous = readText(join(parent, "todos.prev.json"));
    if (current === undefined && previous === undefined) return undefined;
    let prev: string | undefined;
    if (previous !== undefined) {
      prev = newListId(this.dir);
      writeFile(listPath(this.dir, prev), serialize(parse(previous)));
      rmSync(join(parent, "todos.prev.json"), { force: true });
    }
    const id = newListId(this.dir);
    writeFile(listPath(this.dir, id), serialize({ ...parse(current), ...(prev ? { prev } : {}) }));
    rmSync(join(parent, "todos.json"), { force: true });
    return id;
  }

  // Gives a session an entry for a list.
  private link(session: string, list: string): void {
    const map = readSessions(this.dir);
    map[session] = list;
    writeSessions(this.dir, map);
  }

  // Another anvim on this session made its list.
  private adopt(): void {
    if (this.list || !this.session) return;
    this.list = readSessions(this.dir)[this.session];
    if (this.list) this.sync();
  }

  // Each init of the main thread. A new session id, after /clear, a fork or
  // a rewind, takes the current list, unless it has a list of its own.
  async bind(session: string): Promise<void> {
    if (session === this.session) return;
    try {
      await this.locked(() => this.take(session));
    } catch (err) {
      process.stderr.write(`could not link session ${session} to its todo list: ${err}\n`);
    }
    this.session = session;
    this.sync();
  }

  read(): TodoFile {
    if (this.list) return parse(readText(listPath(this.dir, this.list)));
    return parse(this.legacy ? readText(join(dirname(this.dir), "todos.json")) : undefined);
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

  // /reset sends a /clear prompt with this id.
  armReset(id: string): void {
    this.resets.add(id);
  }

  // conversation_reset, ahead of the new session's init. The /clear of a
  // /reset starts a new list, whose prev is the old one, and the init gives
  // the new session the new list. An empty list stays, so a second /reset
  // loses nothing.
  async cleared(id: string | undefined): Promise<void> {
    if (id === undefined || !this.resets.delete(id)) return;
    try {
      await this.locked(() => {
        if (!this.list || this.read().items.length === 0) return;
        const list = newListId(this.dir);
        writeFile(listPath(this.dir, list), serialize({ next_id: 1, items: [], prev: this.list }));
        this.list = list;
      });
    } catch (err) {
      process.stderr.write(`could not start a new todo list: ${err}\n`);
    } finally {
      this.resend();
    }
  }

  // /undo-reset: the list and its prev swap places, so a second undo swaps
  // them back. False when there is no previous list.
  async undo(): Promise<boolean> {
    const swapped = await this.locked(() => {
      const current = this.list;
      const prev = this.read().prev;
      const text = prev && readText(listPath(this.dir, prev));
      if (!current || !prev || text === undefined) return false;
      writeFile(listPath(this.dir, prev), serialize({ ...parse(text), prev: current }));
      this.list = prev;
      if (this.session) this.link(this.session, prev);
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

  // Reads, changes and writes the list under the lock. A change that throws
  // writes nothing. The first change makes the list.
  private async change<T>(fn: (file: TodoFile) => T): Promise<{ result: T; items: TodoItem[] }> {
    const { result, items } = await this.locked(() => {
      // Another anvim on this session may have made the list meanwhile.
      if (!this.list && this.session) this.list = readSessions(this.dir)[this.session];
      if (!this.list && this.legacy) {
        this.list = this.migrate();
        this.legacy = false;
      }
      const file = this.read();
      const result = fn(file);
      if (!this.list) {
        this.list = newListId(this.dir);
        if (this.session) this.link(this.session, this.list);
      }
      writeFile(listPath(this.dir, this.list), serialize(file));
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
    return join(this.dir, ".lock");
  }

  private async lock(): Promise<void> {
    mkdirSync(this.dir, { recursive: true });
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
  // prompt tells: this hook can run before the store sees that a /reset
  // started a new list.
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
