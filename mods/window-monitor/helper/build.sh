#!/bin/sh
# Builds the capture helper from the Swift sources next to this script into
# ../.bin/window-monitor-helper (a hidden folder, so Herdr does not reload the
# mod when the binary changes), plus a copy, ../.bin/window-monitor-lister,
# that the window picker runs: ScreenCaptureKit interrupts every running
# capture of an executable when another process of that same executable path
# connects, so listing and thumbnails must not run as window-monitor-helper.
# Needs the Xcode Command Line Tools (`xcode-select --install`). Runs locally;
# downloads nothing.
set -eu
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found: install the Xcode Command Line Tools with: xcode-select --install" >&2
  exit 3
fi
mkdir -p ../.bin
out=../.bin/window-monitor-helper
xcrun swiftc -O -swift-version 5 -parse-as-library -import-objc-header zlib_bridge.h -lz \
  -framework ScreenCaptureKit -framework Accelerate \
  Main.swift StageMetrics.swift PNG.swift PNGFiles.swift Thumbnails.swift -o "$out.new"
# The helper goes last: the mod treats its presence as "both are built".
cp -f "$out.new" ../.bin/window-monitor-lister.new
mv -f ../.bin/window-monitor-lister.new ../.bin/window-monitor-lister
mv -f "$out.new" "$out"
echo "built $(cd ../.bin && pwd)/window-monitor-helper and window-monitor-lister"
