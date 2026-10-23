// Images that the user pasted into a prompt, as content blocks for Claude.
import { readFileSync, statSync } from "node:fs";
import { basename, extname } from "node:path";

type MediaType = "image/png" | "image/jpeg" | "image/gif" | "image/webp";
export type ImageBlock = { type: "image"; source: { type: "base64"; media_type: MediaType; data: string } };

const TYPES: Record<string, MediaType> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};
// The API refuses an image whose base64 text is longer. An image that it
// refused would stay in the session and fail every later request.
export const MAX_BASE64 = 5 * 1024 * 1024;
// The largest file, in MB, rounded down, as base64 makes 4 bytes of 3.
const MAX_MB = Math.floor(((MAX_BASE64 / 4) * 3 * 10) / 1024 / 1024) / 10;

// The blocks of the images that Claude can take. Each other one gets a notice.
export function imageBlocks(paths: string[], notice: (text: string) => void): ImageBlock[] {
  const blocks: ImageBlock[] = [];
  for (const path of paths) {
    const name = basename(path);
    const media_type = TYPES[extname(path).toLowerCase()];
    try {
      if (!media_type) throw new Error("not a PNG, JPEG, GIF or WebP file");
      const size = statSync(path).size;
      if (Math.ceil(size / 3) * 4 > MAX_BASE64) {
        notice(`Claude did not get ${name}: at ${(size / 1024 / 1024).toFixed(1)} MB, it is larger than ${MAX_MB} MB.`);
        continue;
      }
      blocks.push({ type: "image", source: { type: "base64", media_type, data: readFileSync(path).toString("base64") } });
    } catch (err) {
      notice(`Claude did not get ${name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  return blocks;
}
