#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/dev.sh"
TEST_ROOT="$(mktemp -d "$SCRIPT_DIR/.dev-test.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
RM_LOG="$TEST_ROOT/rm.log"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME/Library/Developer/Xcode/DerivedData" "$MOCK_BIN"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RM_LOG"
EOF
cat > "$MOCK_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$XCODEBUILD_ARGS_LOG"
EOF
cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  printf '%s\n' "$MOCK_HOST_ARCH"
else
  /usr/bin/uname "$@"
fi
EOF
cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n hw.optional.arm64" ]]; then
  printf '%s\n' "${MOCK_APPLE_SILICON:-1}"
else
  exit 1
fi
EOF
cat > "$MOCK_BIN/open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/pgrep" "$MOCK_BIN/rm" "$MOCK_BIN/xcodebuild" "$MOCK_BIN/uname" "$MOCK_BIN/sysctl" "$MOCK_BIN/open"

PATH="$MOCK_BIN:$PATH"
export HOME="$TEST_HOME" PATH RM_LOG XCODEBUILD_ARGS_LOG="$TEST_ROOT/xcodebuild-args.log"

unset DERIVED_DATA_PATH
default_path="$HOME/Library/Developer/Xcode/DerivedData/DictateAnywhereDev"

if ! "$SCRIPT" clean >/dev/null; then
  printf 'FAIL: the default project directory was rejected\n' >&2
  exit 1
fi
if [[ "$(<"$RM_LOG")" != "-rf -- $default_path" ]]; then
  printf 'FAIL: clean did not target the exact default project directory\n' >&2
  exit 1
fi

/bin/rm -rf -- "$HOME/Library/Developer/Xcode/DerivedData"
redirected_target="$TEST_ROOT/redirect-target/DictateAnywhereDev"
mkdir -p "$redirected_target"
printf 'must survive\n' > "$redirected_target/marker"
mkdir -p "$HOME/Library/Developer/Xcode"
ln -s "$TEST_ROOT/redirect-target" "$HOME/Library/Developer/Xcode/DerivedData"
if "$SCRIPT" clean >/dev/null 2>&1; then
  printf 'FAIL: clean followed a symlinked DerivedData parent\n' >&2
  exit 1
fi
if [[ ! -e "$redirected_target/marker" ]]; then
  printf 'FAIL: the redirected clean target was deleted\n' >&2
  exit 1
fi
/bin/rm "$HOME/Library/Developer/Xcode/DerivedData"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"

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

executable="$default_path/Build/Products/Debug/Dictate Anywhere Dev.app/Contents/MacOS/Dictate Anywhere Dev"
mkdir -p "$(dirname "$executable")"
touch "$executable"
chmod +x "$executable"

for scenario in native-arm64 native-intel rosetta; do
  case "$scenario" in
    native-arm64) shell_arch=arm64; apple_silicon=1; native_arch=arm64 ;;
    native-intel) shell_arch=x86_64; apple_silicon=0; native_arch=x86_64 ;;
    rosetta) shell_arch=x86_64; apple_silicon=1; native_arch=arm64 ;;
  esac
  for command in build launch test benchmark check; do
    MOCK_HOST_ARCH="$shell_arch" MOCK_APPLE_SILICON="$apple_silicon" "$SCRIPT" "$command" >/dev/null
    if ! /usr/bin/grep -Fxq "platform=macOS,arch=$native_arch" "$XCODEBUILD_ARGS_LOG" || \
       /usr/bin/grep -Eq '^ARCHS=' "$XCODEBUILD_ARGS_LOG"; then
      printf 'FAIL: %s did not select a native macOS destination for %s\n' "$command" "$scenario" >&2
      exit 1
    fi
  done
done

assert_benchmark_arg() {
  /usr/bin/grep -Fxq -- "$1" "$XCODEBUILD_ARGS_LOG" || {
    printf 'FAIL: missing benchmark argument: %s\n' "$1" >&2
    exit 1
  }
}

assert_benchmark_selector_count() {
  local count
  count="$(/usr/bin/grep -c '^-only-testing:' "$XCODEBUILD_ARGS_LOG")"
  [[ "$count" == "$1" ]] || {
    printf 'FAIL: expected %s focused selectors, got %s\n' "$1" "$count" >&2
    exit 1
  }
}

/bin/rm -f "$XCODEBUILD_ARGS_LOG"
"$SCRIPT" benchmark --list > "$TEST_ROOT/benchmark-list.log"
[[ ! -e "$XCODEBUILD_ARGS_LOG" ]] || { printf 'FAIL: --list invoked Xcode\n' >&2; exit 1; }
for group in all asr preview audio overlay transcript insertion cloud-request recovery cleanup model-switch; do
  /usr/bin/grep -Eq "^$group +" "$TEST_ROOT/benchmark-list.log" || {
    printf 'FAIL: group %s missing from --list\n' "$group" >&2
    exit 1
  }
done

"$SCRIPT" benchmark --only overlay >/dev/null
assert_benchmark_selector_count 2
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/OverlayContentTests'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/OverlayPerformanceBenchmarkTests'
assert_benchmark_arg 'SWIFT_OPTIMIZATION_LEVEL=-O'
assert_benchmark_arg "$default_path/Logs/Test/DictateAnywhere-Benchmark.xcresult"

"$SCRIPT" benchmark --only audio,overlay --only audio --only cleanup >/dev/null
assert_benchmark_selector_count 7
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelinePerformanceBenchmarkTests/testAudioPollingBenchmark'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelineWorkloadBenchmarkTests/testPCMBufferConstruction'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelinePerformanceBenchmarkTests/testS1MiniPrewarmBenchmark'

"$SCRIPT" benchmark >/dev/null
assert_benchmark_selector_count 18
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/RecoveryASRSmokeTests/testRepeatableOfflineASRBenchmark'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/ModelSwitchBenchmarkTests/testModelSwitchTimings'

touch "$TEST_ROOT/Signing.local.xcconfig"
SIGNING_CONFIG_PATH="$TEST_ROOT/Signing.local.xcconfig" \
  PIPELINE_BENCHMARK_ITERATIONS=7 "$SCRIPT" benchmark --only overlay --release >/dev/null
assert_benchmark_selector_count 2
assert_benchmark_arg Release
assert_benchmark_arg 'CODE_SIGN_IDENTITY=Apple Development'
assert_benchmark_arg 'ENABLE_TESTABILITY=YES'
assert_benchmark_arg 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=PIPELINE_BENCHMARK PIPELINE_BENCHMARK_OPTIMIZED'

for invalid in unknown '' ',overlay' 'overlay,' 'overlay,,audio'; do
  /bin/rm -f "$XCODEBUILD_ARGS_LOG"
  if "$SCRIPT" benchmark --only "$invalid" >/dev/null 2>&1; then
    printf 'FAIL: invalid benchmark group accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -e "$XCODEBUILD_ARGS_LOG" ]] || { printf 'FAIL: invalid group invoked Xcode\n' >&2; exit 1; }
done
if "$SCRIPT" benchmark --only >/dev/null 2>&1 || \
   "$SCRIPT" benchmark --only --list >/dev/null 2>&1 || \
   "$SCRIPT" test --only overlay >/dev/null 2>&1; then
  printf 'FAIL: missing benchmark group or benchmark-only flag accepted\n' >&2
  exit 1
fi

printf 'Development script architecture selection tests passed.\n'
printf 'Development script clean safety tests passed.\n'
printf 'Benchmark discovery, focused/combined/default selection, signing and invalid-input tests passed.\n'
