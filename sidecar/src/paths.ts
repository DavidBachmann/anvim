// Paths as the system resolves them, and as the user reads them.
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, sep } from "node:path";

// A path as the system resolves it, with symlinks followed. A part that does
// not exist yet keeps its name, so a new file resolves through its nearest
// existing parent.
export function realPath(path: string): string {
  let dir: string = sep;
  for (const part of path.split(sep)) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      dir = dirname(dir);
      continue;
    }
    const next = join(dir, part);
    try {
      dir = realpathSync.native(next);
    } catch {
      dir = next;
    }
  }
  return dir;
}

export function inside(path: string, dir: string): boolean {
  return path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep);
}

// A path under the home dir, written with ~.
export function tildePath(path: string, home = homedir()): string {
  return inside(path, home) ? "~" + path.slice(home.length) : path;
}
