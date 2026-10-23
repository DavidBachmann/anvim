import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { imageBlocks, MAX_BASE64 } from "./images";

test("sends a pasted image as a base64 block, and skips one that Claude cannot take, with a notice", () => {
  const dir = mkdtempSync(join(tmpdir(), "anvim-images-"));
  try {
    const small = join(dir, "shot.PNG");
    writeFileSync(small, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const large = join(dir, "big.jpg");
    writeFileSync(large, "");
    truncateSync(large, (MAX_BASE64 / 4) * 3 + 1);
    const notices: string[] = [];
    const blocks = imageBlocks([small, large, join(dir, "gone.png"), join(dir, "notes.txt")], (t) => notices.push(t));
    expect(blocks).toEqual([{ type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw==" } }]);
    expect(notices.length).toBe(3);
    expect(notices[0]).toStartWith("Claude did not get big.jpg: at 3.8 MB");
    expect(notices[1]).toStartWith("Claude did not get gone.png: ENOENT");
    expect(notices[2]).toBe("Claude did not get notes.txt: not a PNG, JPEG, GIF or WebP file");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
