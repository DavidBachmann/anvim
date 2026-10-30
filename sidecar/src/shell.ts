// Shell command lines, as far as the Bash guard (sandbox.ts) needs to read
// them for sandbox.excludedCommands.
import { basename } from "node:path";

// The commands of a command line, split at ;, &, &&, ||, |, newlines,
// parentheses and backticks outside single quotes. A $( opens a command too.
export function commandParts(line: string): string[] {
  const parts: string[] = [];
  let part = "";
  let quote: string | undefined;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (quote === "'") {
      part += c;
      if (c === "'") quote = undefined;
    } else if (c === "\\" && i + 1 < line.length) {
      part += c + line[++i];
    } else if (c === "'" && !quote) {
      quote = c;
      part += c;
    } else if (c === '"') {
      quote = quote ? undefined : c;
      part += c;
    } else if (c === "&" && (line[i - 1] === ">" || line[i - 1] === "<" || line[i + 1] === ">")) {
      // A redirection such as 2>&1 or &>file.
      part += c;
    } else if (";&|\n()`".includes(c) && (!quote || "()`".includes(c))) {
      // A command inside double quotes, as in "$(touch x)", runs too.
      parts.push(part.replace(/\$$/, ""));
      part = "";
      if (line[i + 1] === c && c !== "(" && c !== ")") i++;
    } else {
      part += c;
    }
  }
  parts.push(part);
  return parts.map((p) => p.trim()).filter(Boolean);
}

// Words that run the rest of the line as a command, with the GNU names that
// macOS gives coreutils, and shell keywords that come before a command.
const WRAPPERS = new Set(
  ["env", "timeout", "time", "nice", "nohup", "stdbuf", "noglob", "command", "builtin", "exec", "sudo", "xargs"].flatMap(
    (w) => [w, "g" + w],
  ),
);
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*\+?=/;

// A word as the shell reads it: without quotes and backslashes.
function unquote(word: string): string {
  return word.replace(/\\(.)/g, "$1").replace(/["']/g, "");
}

// A part's words, and the places where its command can start: the first word
// after VAR=value words and keywords, and after a wrapper every later word,
// because the wrapper's options can take values.
function commandWords(part: string): { words: string[]; starts: number[] } {
  const words = (part.match(/(?:"(?:\\.|[^"\\])*"?|'[^']*'?|\\.|[^\s"'\\])+/g) ?? [])
    .map(unquote)
    .map((w) => w.replace(/^\d*[<>]+&?\S*$/, ""))
    .filter(Boolean);
  const starts: number[] = [];
  for (let i = 0; i < words.length; i++) {
    const word = words[i]!;
    if (ASSIGNMENT.test(word) || KEYWORDS.has(word)) continue;
    starts.push(i);
    if (WRAPPERS.has(basename(word))) for (let j = i + 1; j < words.length; j++) starts.push(j);
    break;
  }
  return { words, starts };
}

// The words of an entry before its first `*`. Each command that the entry
// matches starts with them, since Claude Code matches a rule from the start
// of a command. The last word is only a prefix when the `*` is part of it.
type EntryWords = { words: string[]; partial: boolean };

// Undefined when the first word has a `*`: such an entry can match any command.
function entryWords(entry: string): EntryWords | undefined {
  const text = entry.trim().replace(/:\*$/, "");
  const star = text.search(/(?<!\\)\*/);
  const head = star < 0 ? text : text.slice(0, star);
  const words = head.split(/\s+/).filter(Boolean).map(unquote);
  const partial = star >= 0 && !/\s$/.test(head);
  if (words.length === 0 || (partial && words.length === 1)) return undefined;
  return { words, partial };
}

function startsWith(words: string[], at: number, entry: EntryWords): boolean {
  return entry.words.every((want, k) => {
    const word = words[at + k];
    if (word === undefined) return false;
    const prefix = entry.partial && k === entry.words.length - 1;
    // The command word may be a path, such as /usr/bin/touch.
    return (k === 0 ? [word, basename(word)] : [word]).some((w) => (prefix ? w.startsWith(want) : w === want));
  });
}

// Whether Claude Code could run a command outside the sandbox because of
// sandbox.excludedCommands. Claude Code runs a line outside it when each of
// its commands matches an entry, after it strips VAR=value words, wrappers
// such as timeout and quotes. Its parser has more forms than anvim can follow,
// so anvim asks for any line in which a command starts with an entry's words
// before its first `*`. That asks for some lines that Claude Code keeps in the
// sandbox.
export function excludedCommand(line: string, entries: string[]): boolean {
  const parsed = entries.filter((e) => typeof e === "string" && e.trim() !== "").map(entryWords);
  if (parsed.length === 0) return false;
  if (parsed.includes(undefined)) return true;
  return commandParts(line).some((part) => {
    const { words, starts } = commandWords(part);
    return starts.some((at) => parsed.some((entry) => startsWith(words, at, entry!)));
  });
}
