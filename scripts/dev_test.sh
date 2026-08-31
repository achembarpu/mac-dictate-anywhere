#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/dev.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/var/tmp}/dictate-anywhere-dev-test.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
RM_LOG="$TEST_ROOT/rm.log"
mkdir -p "$MOCK_BIN"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RM_LOG"
EOF
chmod +x "$MOCK_BIN/pgrep" "$MOCK_BIN/rm"

PATH="$MOCK_BIN:$PATH"
export PATH RM_LOG

default_path="$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"

if ! "$SCRIPT" clean >/dev/null; then
  printf 'FAIL: the default project directory was rejected\n' >&2
  exit 1
fi
if [[ "$(<"$RM_LOG")" != "-rf -- $default_path" ]]; then
  printf 'FAIL: clean did not target the exact default project directory\n' >&2
  exit 1
fi

dangerous_paths=(
  "/"
  "$HOME"
  "$SCRIPT_DIR/.."
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/custom-derived-data"
)
for dangerous_path in "${dangerous_paths[@]}"; do
  if DERIVED_DATA_PATH="$dangerous_path" "$SCRIPT" clean >/dev/null 2>&1; then
    printf 'FAIL: dangerous clean path was accepted: %s\n' "$dangerous_path" >&2
    exit 1
  fi
done

if [[ "$(wc -l < "$RM_LOG" | tr -d ' ')" != "1" ]]; then
  printf 'FAIL: a rejected clean path reached rm\n' >&2
  exit 1
fi

printf 'Development script clean safety tests passed.\n'
