#!/usr/bin/env bash
set -euo pipefail

# Audit the complete bundle, including updater apps, XPC services and libraries.
# Signature/notarization checks alone do not establish architecture support.
fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

[[ "$#" == 1 ]] || fail "Usage: $(basename "$0") /path/to/App.app"
APP_PATH="$1"
[[ -d "$APP_PATH" ]] || fail "App bundle not found: $APP_PATH"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[[ -f "$EXECUTABLE_PATH" && -x "$EXECUTABLE_PATH" ]] || fail "App executable not found: $EXECUTABLE_PATH"
[[ "$(/usr/bin/file -b "$EXECUTABLE_PATH")" == *Mach-O* ]] || fail "App executable is not Mach-O: $EXECUTABLE_PATH"

find "$APP_PATH" -type f -print0 | (
  binary_count=0
  while IFS= read -r -d '' binary; do
    [[ -r "$binary" ]] || fail "Cannot inspect unreadable file: $binary"
    description="$(/usr/bin/file -b "$binary")"
    [[ "$description" == *Mach-O* ]] || continue
    for architecture in arm64 x86_64; do
      xcrun lipo "$binary" -verify_arch "$architecture" || \
        fail "Missing $architecture architecture: $binary"
    done
    printf 'Universal: %s\n' "${binary#"$APP_PATH"/}"
    binary_count=$((binary_count + 1))
  done

  [[ "$binary_count" -gt 0 ]] || fail "No Mach-O binaries found in: $APP_PATH"
  printf 'Verified %s universal binaries (arm64 + x86_64).\n' "$binary_count"
)
