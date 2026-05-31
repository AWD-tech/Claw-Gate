#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Claw Gate.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$MACOS/ClawGate"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

/usr/bin/swiftc \
  -O \
  -parse-as-library \
  -target "$ARCH-apple-macosx13.0" \
  -framework AppKit \
  -framework Combine \
  -framework Foundation \
  -framework SwiftUI \
  "$ROOT/Sources/OpenClawMenuBar/main.swift" \
  -o "$BIN"

cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
chmod +x "$BIN"

echo "Built $APP"
