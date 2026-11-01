#!/bin/bash
# Wrap a built darkbloom in a throwaway .app with a unique CFBundleIdentifier, so the process gets
# its own empty per-app Metal shader cache ($DARWIN_USER_CACHE_DIR/<id>/com.apple.metal), like a
# fresh install or the first start after a macOS or MLX kernel-source update. Prints the executable.
# Usage: make_bundle.sh <dir-with-darkbloom-and-mlx.metallib> <bundle-id> <dest-root>
set -eu
SRC="$1"; ID="$2"; ROOT="$3"
APP="$ROOT/$ID/Darkbloom.app"
mkdir -p "$APP/Contents/MacOS"
cp -c "$SRC/darkbloom" "$APP/Contents/MacOS/darkbloom" 2>/dev/null || cp "$SRC/darkbloom" "$APP/Contents/MacOS/darkbloom"
cp -c "$SRC/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib" 2>/dev/null || cp "$SRC/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>darkbloom</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleName</key><string>Darkbloom</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PL
echo "$APP/Contents/MacOS/darkbloom"
