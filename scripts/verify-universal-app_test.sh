#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-universal-app.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
APP="$TEST_ROOT/Fixture with spaces.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks/Updater.app/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string></dict></plist>
EOF
printf 'int main(void) { return 0; }\n' > "$TEST_ROOT/fixture.c"
# Real Mach-O objects exercise lipo without signing or launching test apps.
for architecture in arm64 x86_64; do
  xcrun clang -arch "$architecture" -c "$TEST_ROOT/fixture.c" -o "$TEST_ROOT/$architecture.o"
done
xcrun lipo -create "$TEST_ROOT/arm64.o" "$TEST_ROOT/x86_64.o" -output "$TEST_ROOT/universal"
cp "$TEST_ROOT/universal" "$APP/Contents/MacOS/Fixture"
chmod +x "$APP/Contents/MacOS/Fixture"
printf 'Resource data is not executable code.\n' > "$APP/Contents/Resources/text.txt"
ln -s Fixture "$APP/Contents/MacOS/ExecutableAlias"
"$VERIFY" "$APP" > "$TEST_ROOT/output"
/usr/bin/grep -Eq 'Verified 1 universal binaries' "$TEST_ROOT/output"

expect_failure() {
  if "$VERIFY" "$APP" > "$TEST_ROOT/output" 2>&1; then
    printf 'FAIL: %s was accepted\n' "$1" >&2
    exit 1
  fi
  /usr/bin/grep -Eq "$2" "$TEST_ROOT/output"
}

for architecture in arm64 x86_64; do
  cp "$TEST_ROOT/$architecture.o" "$APP/Contents/MacOS/Fixture"
  expect_failure "$architecture-only main executable" 'Missing (arm64|x86_64) architecture'
done
cp "$TEST_ROOT/universal" "$APP/Contents/MacOS/Fixture"
helper="$APP/Contents/Frameworks/Updater.app/Contents/MacOS/Updater"
for architecture in arm64 x86_64; do
  cp "$TEST_ROOT/$architecture.o" "$helper"
  expect_failure "$architecture-only nested helper" 'Updater.app/Contents/MacOS/Updater'
done
cp "$TEST_ROOT/universal" "$helper"
"$VERIFY" "$APP" > "$TEST_ROOT/output"
/usr/bin/grep -Eq 'Verified 2 universal binaries' "$TEST_ROOT/output"
printf 'Not an executable.\n' > "$APP/Contents/MacOS/Fixture"
expect_failure 'non-Mach-O main executable' 'App executable is not Mach-O'
rm "$APP/Contents/MacOS/Fixture"
expect_failure 'missing main executable' 'App executable not found'
printf 'Universal bundle verification tests passed.\n'
