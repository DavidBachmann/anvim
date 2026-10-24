// Converts an image to a PNG for snacks.image, which can send only PNGs to
// the terminal. It runs when ImageMagick is missing, and fits the image in
// 1920x1080, as snacks does with ImageMagick.
// Usage: bun src/topng.ts <image> <png>
const [src, out] = process.argv.slice(2);
if (!src || !out) {
  console.error("usage: bun src/topng.ts <image> <png>");
  process.exit(2);
}
await new Bun.Image(src).resize(1920, 1080, { fit: "inside", withoutEnlargement: true }).png().write(out);
