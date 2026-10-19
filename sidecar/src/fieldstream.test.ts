import { describe, expect, test } from "bun:test";
import { FieldStream, type FieldEvent } from "./fieldstream";

function feed(chunks: string[]): FieldEvent[] {
  const fs = new FieldStream();
  return chunks.flatMap((c) => fs.push(c));
}

function strings(events: FieldEvent[]): Record<string, string> {
  const acc: Record<string, string> = {};
  for (const e of events) {
    if (e.kind === "start" && e.string) acc[e.key] = "";
    if (e.kind === "delta") acc[e.key] += e.text;
  }
  return acc;
}

function ends(events: FieldEvent[]): Record<string, unknown> {
  const acc: Record<string, unknown> = {};
  for (const e of events) if (e.kind === "end") acc[e.key] = e.value;
  return acc;
}

describe("FieldStream", () => {
  const input = {
    file_path: "/tmp/a.lua",
    old_string: 'print("hi")\n',
    new_string: 'print("hello \\"world\\"")\n\ttabbed ☃ 🎉',
    replace_all: false,
    limit: 20,
    edits: [{ a: "x,}]" }, [1, 2]],
  };
  const json = JSON.stringify(input, null, 1);

  test("whole object in one chunk", () => {
    const events = feed([json]);
    expect(ends(events)).toEqual(input);
  });

  test("every possible single split point gives the same result", () => {
    for (let i = 0; i <= json.length; i++) {
      const events = feed([json.slice(0, i), json.slice(i)]);
      expect(ends(events)).toEqual(input);
      expect(strings(events).new_string).toBe(input.new_string);
    }
  });

  test("one character per chunk, with unicode escapes and surrogate pairs", () => {
    const escaped = JSON.stringify({ s: "aé" }).replace("é", "\\u00e9") + "";
    const withPair = '{"s": "x\\ud83c\\udf89y", "n": null}';
    for (const src of [escaped, withPair]) {
      const events = feed([...src]);
      const deltas = events.filter((e) => e.kind === "delta");
      for (const d of deltas) {
        if (d.kind !== "delta") continue;
        const last = d.text.charCodeAt(d.text.length - 1);
        expect(last >= 0xd800 && last <= 0xdbff).toBe(false);
      }
      expect(ends(events)).toEqual(JSON.parse(src));
    }
  });

  test("streams string deltas before the value ends", () => {
    const fs = new FieldStream();
    expect(fs.push('{"file_path": "/a.l')).toEqual([
      { kind: "start", key: "file_path", string: true },
      { kind: "delta", key: "file_path", text: "/a.l" },
    ]);
    expect(fs.push('ua", "content": "line1\\nli')).toEqual([
      { kind: "delta", key: "file_path", text: "ua" },
      { kind: "end", key: "file_path", value: "/a.lua" },
      { kind: "start", key: "content", string: true },
      { kind: "delta", key: "content", text: "line1\nli" },
    ]);
    expect(fs.done).toBe(false);
    fs.push('ne2"}');
    expect(fs.done).toBe(true);
  });

  test("empty object and leading empty chunk", () => {
    const fs = new FieldStream();
    expect(fs.push("")).toEqual([]);
    expect(fs.push("{}")).toEqual([]);
    expect(fs.done).toBe(true);
  });
});
