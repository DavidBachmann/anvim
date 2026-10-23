// Starts anvim for one test: the real init.lua with the plugins in .tests/anvim,
// on a temp copy of the fixture project, with temp Neovim dirs and a replay sidecar.
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Pos } from "../../sidecar/src/screen.ts";
import { root, Ui, type Frame } from "../../tools/screen/ui.ts";

// A window's cells on the grid, 0-based.
export type Box = { row: number; col: number; width: number; height: number };
export type Where = { win: string; mode: string };

export const inBox = (pos: Pos, box: Box) =>
  pos.row >= box.row && pos.row < box.row + box.height && pos.col >= box.col && pos.col < box.col + box.width;

// The cursor of each frame that has it inside the box.
export const cursorIn = (frames: Frame[], box: Box) => frames.flatMap((f) => (inBox(f.cursor, box) ? [f.cursor] : []));

// The text of a row from a column on. Code points match cells, because each
// glyph that anvim and the explorer draw is one cell wide.
export const cells = (line: string, col: number, width: number) => [...line].slice(col, col + width).join("");

// Waits until ok(value) holds, and returns the value. After the timeout it
// returns the last value, so that expect() shows what differs.
export async function settle<T>(get: () => Promise<T>, ok: (value: T) => boolean, timeout = 5000): Promise<T> {
  const deadline = Date.now() + timeout;
  let value = await get();
  while (!ok(value) && Date.now() < deadline) {
    await Bun.sleep(20);
    value = await get();
  }
  return value;
}

// Waits until no frame has come for ms, so that the late frames of a step,
// such as a picker's list, are in the log.
export async function quiet(ui: Ui, ms = 150, timeout = 5000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    const last = ui.frames(Math.max(ui.mark() - 1, 0))[0]?.t ?? 0;
    if (performance.now() - last >= ms) return;
    await Bun.sleep(20);
  }
}

const WHERE = `
  local win = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  for role, w in pairs(require("anvim.layout").wins) do
    if w == win then
      return { win = role, mode = mode }
    end
  end
  return { win = vim.bo.filetype, mode = mode }
`;

const BOX = `
  local role = ...
  local win = require("anvim.layout").wins[role]
  if role == "tree" then
    local side = require("anvim.layout").tree_side()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local snacks_win = vim.w[w].snacks_win
      if vim.api.nvim_win_get_config(w).relative == "" and snacks_win and snacks_win.position == side then
        win = w
      end
    end
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return vim.NIL
  end
  local pos = vim.fn.win_screenpos(win)
  -- The rows of text of the code window and the pane, under their winbars.
  local bar = (role == "code" or role == "pane") and vim.fn.getwininfo(win)[1].winbar or 0
  local height = vim.api.nvim_win_get_height(win) - bar
  return { row = pos[1] - 1 + bar, col = pos[2] - 1, width = vim.api.nvim_win_get_width(win), height = height }
`;

export class Anvim {
  constructor(
    readonly ui: Ui,
    // The project dir, which is the cwd.
    readonly dir: string,
    private tmp: string,
  ) {}

  where(): Promise<Where> {
    return this.ui.exec_lua(WHERE);
  }

  async waitWhere(win: string, mode: string, timeout = 5000) {
    let got: Where | undefined;
    try {
      await this.ui.waitFor(async () => {
        got = await this.where();
        return got.win === win && got.mode === mode;
      }, timeout);
    } catch {
      throw new Error(`want ${win}/${mode}, got ${JSON.stringify(got)}\n${this.ui.screen()}`);
    }
  }

  async box(role: "code" | "pane" | "transcript" | "input" | "tree"): Promise<Box> {
    const box = await this.ui.exec_lua<Box | null>(BOX, role);
    if (!box) throw new Error(`no ${role} window`);
    return box;
  }

  // The footer under the prompt, as the grid shows it.
  async footer(): Promise<string> {
    const input = await this.box("input");
    return cells(this.ui.lines()[input.row + input.height - 1] ?? "", input.col, input.width);
  }

  // Shows a project file in the code window, with the cursor there in normal mode.
  async toCode(file = "matchparen.lua", view?: { lnum: number; topline: number }) {
    await this.ui.exec_lua(
      `
      local path, view = ...
      vim.cmd.stopinsert()
      vim.api.nvim_set_current_win(require("anvim.layout").code_win())
      vim.cmd.edit(path)
      if view ~= vim.NIL then
        vim.fn.winrestview({ lnum = view.lnum, col = 0, topline = view.topline })
      end
    `,
      join(this.dir, file),
      view ?? null,
    );
    await this.waitWhere("code", "n");
  }

  // Fills the transcript with numbered lines.
  notices(n: number, text: string) {
    return this.ui.exec_lua(
      `
      local n, text = ...
      for i = 1, n do
        require("anvim.transcript").notice("warn", text .. " " .. i)
      end
    `,
      n,
      text,
    );
  }

  // Records what the plugin sends to the sidecar, and still sends it.
  capture() {
    return this.ui.exec_lua(`
      local sidecar = require("anvim.sidecar")
      local send = sidecar.send
      _G.anvim_sent = {}
      sidecar.send = function(msg)
        table.insert(_G.anvim_sent, msg)
        return send(msg)
      end
    `);
  }

  answers(): Promise<{ type: string; req: number; behavior: string }[]> {
    return this.ui.exec_lua(`
      return vim.tbl_filter(function(msg)
        return msg.type == "permission_response"
      end, _G.anvim_sent)
    `);
  }

  // Starts typing in the prompt, which anvim opens in normal mode.
  async insert() {
    await this.ui.input("i");
    await this.waitWhere("input", "i");
  }

  // Types text one key at a time, at a user's pace.
  async type(text: string, ms = 50) {
    for (const char of text) {
      await this.ui.input(char === "<" ? "<lt>" : char);
      await Bun.sleep(ms);
    }
  }

  async close() {
    await this.ui.close();
    rmSync(this.tmp, { recursive: true, force: true });
  }
}

export type AnvimOptions = {
  // A recording in tests/fixtures. Its /ANVIM_FIXTURE placeholder becomes the project dir.
  recording?: string;
  // Edits the recording's frames, one JSON line each, before the replay plays them.
  frames?: (frames: string[]) => string[];
  env?: Record<string, string>;
  // More files in the project dir, by path.
  files?: Record<string, string>;
  // The choices in anvim's prefs.json, as if made at an earlier start. The
  // tool pane is off, so the tool calls show in the chat, unless they say so.
  prefs?: Record<string, unknown>;
  cols?: number;
  rows?: number;
};

export async function start(opts: AnvimOptions = {}): Promise<Anvim> {
  const tmp = realpathSync(mkdtempSync(join(tmpdir(), "anvim-ui-")));
  const dir = join(tmp, "proj");
  mkdirSync(dir);
  copyFileSync(join(root, "tests/fixtures/matchparen.lua"), join(dir, "matchparen.lua"));
  for (const [name, text] of Object.entries(opts.files ?? {})) {
    mkdirSync(dirname(join(dir, name)), { recursive: true });
    writeFileSync(join(dir, name), text);
  }
  let frames = readFileSync(join(root, "tests/fixtures", opts.recording ?? "edit-session.jsonl"), "utf8")
    .replaceAll("/ANVIM_FIXTURE", dir)
    .split("\n")
    .filter(Boolean);
  if (opts.frames) frames = opts.frames(frames);
  const recording = join(tmp, "session.jsonl");
  writeFileSync(recording, frames.join("\n") + "\n");
  mkdirSync(join(tmp, "xdg/state/anvim"), { recursive: true });
  writeFileSync(join(tmp, "xdg/state/anvim/prefs.json"), JSON.stringify({ tool_pane: false, ...opts.prefs }));
  let started: Ui | undefined;
  try {
    const ui = (started = await Ui.start({
      cwd: dir,
      cols: opts.cols,
      rows: opts.rows,
      xdg: join(tmp, "xdg"),
      env: { ANVIM_REPLAY: recording, ANVIM_REPLAY_SPEED: "50", ANVIM_MODEL: "haiku", ...opts.env },
    }));
    const anvim = new Anvim(ui, dir, tmp);
    await ui.waitFor(() =>
      ui.exec_lua(`return package.loaded["anvim.state"] ~= nil and require("anvim.state").process == "ready"`),
    );
    await anvim.waitWhere("input", "n");
    return anvim;
  } catch (err) {
    await started?.close();
    rmSync(tmp, { recursive: true, force: true });
    throw err;
  }
}
