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
printf '%s\n' "${TEST_RUNNER_PIPELINE_BENCHMARK_ACOUSTIC_VARIANTS:-}" > "$XCODEBUILD_ACOUSTIC_ENV_LOG"
printf '%s\n' "${TEST_RUNNER_PIPELINE_BENCHMARK_FIXTURE:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_GOLDEN:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_DOWNLOAD_MODELS:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_ENCODER:-}" > "$XCODEBUILD_ENV_LOG"
printf '%s\n' "${TEST_RUNNER_PIPELINE_BENCHMARK_CLEANUP_MODEL:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_CLEANUP_INPUT_BYTES:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_CLEANUP_GREEDY:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_ASR_URL:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_LANGUAGES:-}" \
  "${TEST_RUNNER_PIPELINE_BENCHMARK_ASR_RESULTS_PATH:-}" > "$XCODEBUILD_RESEARCH_ENV_LOG"
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
export XCODEBUILD_ENV_LOG="$TEST_ROOT/xcodebuild-env.log"
export XCODEBUILD_RESEARCH_ENV_LOG="$TEST_ROOT/xcodebuild-research-env.log"
export XCODEBUILD_ACOUSTIC_ENV_LOG="$TEST_ROOT/xcodebuild-acoustic-env.log"

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
    if [[ "$command" == benchmark ]]; then
      MOCK_HOST_ARCH="$shell_arch" MOCK_APPLE_SILICON="$apple_silicon" "$SCRIPT" benchmark --only audio >/dev/null
    else
      MOCK_HOST_ARCH="$shell_arch" MOCK_APPLE_SILICON="$apple_silicon" "$SCRIPT" "$command" >/dev/null
    fi
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

"$SCRIPT" benchmark --only overlay >/dev/null
assert_benchmark_selector_count 1
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/OverlayPerformanceBenchmarkTests'
assert_benchmark_arg 'SWIFT_OPTIMIZATION_LEVEL=-O'
assert_benchmark_arg "$default_path/Logs/Test/DictateAnywhere-Benchmark.xcresult"

"$SCRIPT" benchmark --only audio,overlay --only audio --only cleanup >/dev/null
assert_benchmark_selector_count 5
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelinePerformanceBenchmarkTests/testAudioPollingBenchmark'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelineWorkloadBenchmarkTests/testPCMBufferConstruction'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/PipelinePerformanceBenchmarkTests/testS1MiniPrewarmBenchmark'

"$SCRIPT" benchmark --only all >/dev/null
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/RecoveryASRSmokeTests/testGoldenSpeechReferenceBenchmark'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/ModelSwitchBenchmarkTests/testModelSwitchTimings'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/TDTVocabularyBenchmarkTests/testVocabularyPreviewAvoidsDiscardedOverlapDecoder'

"$SCRIPT" benchmark --only tdt-vocabulary >/dev/null
assert_benchmark_selector_count 4
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/TDTVocabularyBenchmarkTests/testVocabularyPoliciesAndSharedHead'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/TDTVocabularyBenchmarkTests/testPreparedVocabularyProductionSessions'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/TDTVocabularyBenchmarkTests/testAuxiliaryHeadInstallationAndRepair'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/TDTVocabularyBenchmarkTests/testVocabularyPreviewAvoidsDiscardedOverlapDecoder'

# Check the actual source inventory rather than maintaining a second catalog.
# A stale selector can otherwise make a requested benchmark silently run nothing.
/usr/bin/awk '
  /class [A-Za-z_][A-Za-z_0-9]*.*XCTestCase/ {
    name = $0; sub(/.*class /, "", name); sub(/[^A-Za-z_0-9].*/, "", name)
    print name
  }
  /func test[A-Za-z_0-9]*\(/ {
    method = $0; sub(/.*func /, "", method); sub(/\(.*/, "", method)
    print name "/" method
  }
' "$SCRIPT_DIR/../Dictate AnywhereTests/"*.swift > "$TEST_ROOT/test-inventory"
while IFS= read -r argument; do
  case "$argument" in
    '-only-testing:Dictate AnywhereTests/'*)
      selector="${argument#-only-testing:Dictate AnywhereTests/}"
      if ! /usr/bin/grep -Fxq "$selector" "$TEST_ROOT/test-inventory"; then
        printf 'FAIL: benchmark selector does not resolve: %s\n' "$selector" >&2
        exit 1
      fi
      ;;
  esac
done < "$XCODEBUILD_ARGS_LOG"

"$SCRIPT" benchmark --only s1-regressions >/dev/null
assert_benchmark_selector_count 1
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/S1MiniModelTests'

"$SCRIPT" benchmark --only asr-file >/dev/null
assert_benchmark_selector_count 1
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/GoldenFileASRBenchmarkTests/testInstalledModelsDecodeCompleteGoldenFiles'

touch "$TEST_ROOT/Signing.local.xcconfig"
SIGNING_CONFIG_PATH="$TEST_ROOT/Signing.local.xcconfig" \
  PIPELINE_BENCHMARK_ITERATIONS=7 "$SCRIPT" benchmark --only overlay --release >/dev/null
assert_benchmark_selector_count 1
assert_benchmark_arg Release
assert_benchmark_arg 'CODE_SIGN_IDENTITY=Apple Development'
assert_benchmark_arg 'ENABLE_TESTABILITY=YES'
assert_benchmark_arg 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=PIPELINE_BENCHMARK'

/bin/rm -f "$XCODEBUILD_ARGS_LOG"
if "$SCRIPT" benchmark >/dev/null 2>&1; then
  printf 'FAIL: benchmark ran without an explicit group\n' >&2
  exit 1
fi
[[ ! -e "$XCODEBUILD_ARGS_LOG" ]] || { printf 'FAIL: missing group invoked Xcode\n' >&2; exit 1; }

for invalid in unknown preview insertion s1-context '' ',overlay' 'overlay,' 'overlay,,audio'; do
  /bin/rm -f "$XCODEBUILD_ARGS_LOG"
  if "$SCRIPT" benchmark --only "$invalid" >/dev/null 2>&1; then
    printf 'FAIL: invalid benchmark group accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  [[ ! -e "$XCODEBUILD_ARGS_LOG" ]] || { printf 'FAIL: invalid group invoked Xcode\n' >&2; exit 1; }
done

"$SCRIPT" benchmark --only cleanup-quality,apple-speech-quality >/dev/null
assert_benchmark_selector_count 5
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/DictationStartupContextTests/testAppleDefaultCleanupWithoutPromptOrContext'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/AppleCleanupBenchmarkTests/testLongInputAcrossContextWindows'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/ProviderCleanupBenchmarkTests/testGoldenCleanupWithSelectedProvider'
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/AppleSpeechBenchmarkTests/testInstalledLocalesGoldenSpeechAndFreshSessionPreparation'
if "$SCRIPT" benchmark --only >/dev/null 2>&1 || \
   "$SCRIPT" benchmark --only --list >/dev/null 2>&1 || \
   "$SCRIPT" test --only overlay >/dev/null 2>&1; then
  printf 'FAIL: missing benchmark group or benchmark-only flag accepted\n' >&2
  exit 1
fi

PIPELINE_BENCHMARK_FIXTURE=golden-zh-boundaries PIPELINE_BENCHMARK_GOLDEN=1 \
  PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 \
  PIPELINE_BENCHMARK_ENCODER=1 "$SCRIPT" benchmark --only asr-quality,model-setup >/dev/null
assert_benchmark_selector_count 3
expected_environment=$'golden-zh-boundaries\n1\n1\n1'
if [[ "$(<"$XCODEBUILD_ENV_LOG")" != "$expected_environment" ]]; then
  printf 'FAIL: golden fixture benchmark settings were not forwarded to the test host\n' >&2
  exit 1
fi

PIPELINE_BENCHMARK_CLEANUP_MODEL=candidate \
  PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH='/fixture/prompt with spaces.md' \
  PIPELINE_BENCHMARK_CLEANUP_INPUT_BYTES=512 PIPELINE_BENCHMARK_CLEANUP_GREEDY=1 \
  PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH='/fixture/outputs.json' \
  PIPELINE_BENCHMARK_ASR_URL=http://127.0.0.1:8010/v1 PIPELINE_BENCHMARK_LANGUAGES=en,de \
  PIPELINE_BENCHMARK_ASR_RESULTS_PATH='/fixture/speech outputs.json' \
  "$SCRIPT" benchmark --only cleanup-prompts,external-asr-quality >/dev/null
assert_benchmark_selector_count 5
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/AppleCleanupPromptBenchmarkTests/testCandidatePromptsAgainstGoldenReferences'
expected_research_environment=$'candidate\n/fixture/prompt with spaces.md\n512\n1\n/fixture/outputs.json\nhttp://127.0.0.1:8010/v1\nen,de\n/fixture/speech outputs.json'
if [[ "$(<"$XCODEBUILD_RESEARCH_ENV_LOG")" != "$expected_research_environment" ]]; then
  printf 'FAIL: candidate benchmark settings were not forwarded exactly\n' >&2
  exit 1
fi

printf 'Development script architecture selection tests passed.\n'
PIPELINE_BENCHMARK_ACOUSTIC_VARIANTS=reference-pcm16,reference-gain4 \
  "$SCRIPT" benchmark --only asr-acoustics >/dev/null
assert_benchmark_selector_count 1
assert_benchmark_arg '-only-testing:Dictate AnywhereTests/AcousticASRBenchmarkTests/testQuietFloatAudioAndPCM16GainScreen'
if [[ "$(<"$XCODEBUILD_ACOUSTIC_ENV_LOG")" != 'reference-pcm16,reference-gain4' ]]; then
  printf 'FAIL: acoustic variant selection was not forwarded exactly\n' >&2
  exit 1
fi

printf 'Development script clean safety tests passed.\n'
printf 'Benchmark discovery, focused/combined/explicit-all selection, signing and invalid-input tests passed.\n'
printf 'Golden speech benchmark forwarding tests passed.\n'
printf 'Candidate benchmark forwarding tests passed.\n'
