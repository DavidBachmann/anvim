// Incremental parser for one flat JSON object that arrives in arbitrary chunks,
// such as a tool_use input streamed as input_json_delta. String values stream
// as decoded deltas. Other values (numbers, arrays, objects) arrive whole at end.

export type FieldEvent =
  | { kind: "start"; key: string; string: boolean }
  | { kind: "delta"; key: string; text: string }
  | { kind: "end"; key: string; value: unknown };

const ESCAPES: Record<string, string> = {
  '"': '"',
  "\\": "\\",
  "/": "/",
  b: "\b",
  f: "\f",
  n: "\n",
  r: "\r",
  t: "\t",
};

// Streamed tool input can be invalid JSON. Such a value ends as undefined,
// and the tool_use message still carries the whole input.
function parseRaw(raw: string): unknown {
  try {
    return JSON.parse(raw.trim());
  } catch {
    return undefined;
  }
}

type State =
  | "before_object"
  | "expect_key"
  | "key"
  | "after_key"
  | "before_value"
  | "string"
  | "raw"
  | "done";

export class FieldStream {
  private state: State = "before_object";
  private key = "";
  private value = "";
  private pending = "";
  private escape: string | null = null;
  private highSurrogate: string | null = null;
  private raw = "";
  private rawDepth = 0;
  private rawInString = false;
  private rawEscape = false;

  push(chunk: string): FieldEvent[] {
    const out: FieldEvent[] = [];
    for (const ch of chunk) this.step(ch, out);
    if (this.state === "string" && this.pending) {
      out.push({ kind: "delta", key: this.key, text: this.pending });
      this.pending = "";
    }
    return out;
  }

  get done(): boolean {
    return this.state === "done";
  }

  private step(ch: string, out: FieldEvent[]): void {
    switch (this.state) {
      case "before_object":
        if (ch === "{") this.state = "expect_key";
        return;
      case "expect_key":
        if (ch === '"') {
          this.state = "key";
          this.key = "";
          this.escape = null;
        } else if (ch === "}") {
          this.state = "done";
        }
        return;
      case "key": {
        const decoded = this.decodeStringChar(ch);
        if (decoded === null) this.state = "after_key";
        else this.key += decoded;
        return;
      }
      case "after_key":
        if (ch === ":") this.state = "before_value";
        return;
      case "before_value":
        if (/\s/.test(ch)) return;
        if (ch === '"') {
          this.state = "string";
          this.value = "";
          this.pending = "";
          this.escape = null;
          out.push({ kind: "start", key: this.key, string: true });
        } else {
          this.state = "raw";
          this.raw = "";
          this.rawDepth = 0;
          this.rawInString = false;
          this.rawEscape = false;
          out.push({ kind: "start", key: this.key, string: false });
          this.stepRaw(ch, out);
        }
        return;
      case "string": {
        const decoded = this.decodeStringChar(ch);
        if (decoded === null) {
          if (this.pending) out.push({ kind: "delta", key: this.key, text: this.pending });
          this.pending = "";
          out.push({ kind: "end", key: this.key, value: this.value });
          this.state = "expect_key";
        } else if (decoded) {
          this.value += decoded;
          this.pending += decoded;
        }
        return;
      }
      case "raw":
        this.stepRaw(ch, out);
        return;
      case "done":
        return;
    }
  }

  // Returns the decoded text for ch, "" while inside an escape, or null at the closing quote.
  private decodeStringChar(ch: string): string | null {
    if (this.escape !== null) {
      if (this.escape === "") {
        if (ch === "u") {
          this.escape = "u";
          return "";
        }
        this.escape = null;
        return this.withSurrogate(ESCAPES[ch] ?? ch);
      }
      this.escape += ch;
      if (this.escape.length < 5) return "";
      const unit = String.fromCharCode(parseInt(this.escape.slice(1), 16));
      this.escape = null;
      return this.withSurrogate(unit);
    }
    if (ch === "\\") {
      this.escape = "";
      return "";
    }
    if (ch === '"') return null;
    return this.withSurrogate(ch);
  }

  // Holds a high surrogate back so a delta never ends in half a code point.
  private withSurrogate(text: string): string {
    const code = text.charCodeAt(0);
    if (text.length === 1 && code >= 0xd800 && code <= 0xdbff) {
      this.highSurrogate = text;
      return "";
    }
    if (this.highSurrogate !== null) {
      const joined = this.highSurrogate + text;
      this.highSurrogate = null;
      return joined;
    }
    return text;
  }

  private stepRaw(ch: string, out: FieldEvent[]): void {
    if (this.rawInString) {
      this.raw += ch;
      if (this.rawEscape) this.rawEscape = false;
      else if (ch === "\\") this.rawEscape = true;
      else if (ch === '"') this.rawInString = false;
      return;
    }
    if (this.rawDepth === 0 && (ch === "," || ch === "}")) {
      out.push({ kind: "end", key: this.key, value: parseRaw(this.raw) });
      this.state = ch === "}" ? "done" : "expect_key";
      return;
    }
    this.raw += ch;
    if (ch === '"') this.rawInString = true;
    else if (ch === "{" || ch === "[") this.rawDepth++;
    else if (ch === "}" || ch === "]") this.rawDepth--;
  }
}
