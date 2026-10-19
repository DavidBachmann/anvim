// Prints the CGWindowID of an app's largest on-screen window, for screencapture -l.
// Usage: osascript -l JavaScript tools/screen/window-id.js [app]   (default: cmux)
ObjC.import('CoreGraphics');
function run(argv) {
  const owner = argv[0] || 'cmux';
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  const area = (w) => w.kCGWindowBounds.Width * w.kCGWindowBounds.Height;
  const wins = list.filter((w) => w.kCGWindowOwnerName === owner && w.kCGWindowLayer === 0).sort((a, b) => area(b) - area(a));
  return wins.length ? String(wins[0].kCGWindowNumber) : '';
}
