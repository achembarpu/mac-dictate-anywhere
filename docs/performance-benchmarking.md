# Performance benchmarking

Benchmarks require an explicit group. Configure local Team ID signing and select
only the workload needed for the change:

```sh
scripts/dev.sh signing TEAM_ID
scripts/dev.sh benchmark --list
BENCHMARK_EVIDENCE_DIR=/absolute/path/outside/checkout
DERIVED_DATA_PATH="$BENCHMARK_EVIDENCE_DIR/derived" scripts/dev.sh benchmark --only overlay
DERIVED_DATA_PATH="$BENCHMARK_EVIDENCE_DIR/derived" scripts/dev.sh benchmark --release --only audio,recovery
```

`--only` accepts comma-separated groups and repeated options; duplicates are
removed. Bare `benchmark`, empty groups and unknown groups fail before building.
`--only all` explicitly selects every registered group. Group descriptions and
Xcode selectors have one source of truth in `scripts/dev.sh`; the shell tests
check that those selectors resolve to current test classes and methods.

Ordinary `scripts/dev.sh test` excludes benchmark and installed-model code at
compile time. Benchmark commands compile both app and harness with `-O` and
`PIPELINE_BENCHMARK`. Debug is useful for focused comparisons; `--release` also
uses optimized dependencies, testability and the ignored Team ID signing override.
Keep a stable DerivedData directory per worktree. Benchmark results use a separate
`DictateAnywhere-Benchmark.xcresult` bundle.

## Regression tests

After configuring ignored Team ID signing, run `scripts/dev.sh build` and
`scripts/dev.sh test` for the normal Debug suite. `scripts/dev_test.sh` checks
command selection, signing and environment forwarding without invoking Xcode;
the Python collector checks live in `scripts/tests/`.

Keep regression tests that detect a distinct user-visible failure or external
contract violation. Assert consumer outcomes with independent references; avoid
copied implementation formulas, constant/enum assertions and screenshots without
a comparison oracle. Use fixture tables when cases share setup and behavior.
Keep ordering-sensitive lifecycle/cancellation cases separate. Browser, live
provider and microphone integration checks also compile only for selected
workloads and require their explicit environment opt-ins.

## Choose the smallest useful run

| Groups | Purpose |
| --- | --- |
| `audio`, `overlay`, `transcript`, `cloud-request`, `recovery` | Model-free current-path timing: meter polling, PCM buffers, preview suffixes, transcript assembly, multipart encoding and recovery I/O. No network or microphone. |
| `audio-conversion` | Continuous capture conversion against reset-per-block conversion, exact whole-stream PCM continuity, golden decode quality and direct recovery PCM read work. |
| `audio-hardware`, `browser-context`, `live-insertion` | Explicit microphone, isolated Chromium, or live AssemblyAI integration. Each also requires its environment opt-in; microphone checks use Debug. |
| `asr` | One supplied recording and reference: recovery decode latency and WER. |
| `asr-quality` | Independent human goldens through live batch replay/native recovery; optional encoder placement comparison. |
| `asr-regressions` | Installed-model prepare/recovery isolation, v2 vocabulary seams, batch cancellation/tails and cancelled previews, quiet speech versus noise and Apple recovery. |
| `asr-file`, `asr-acoustics` | Whole-file accuracy/resources and bounded acoustic experiments. |
| `model-setup` | Explicit selected-model installation into the app cache; requires the download flag. |
| `cleanup`, `s1-prepare` | Installed S1 cleanup or cold/prepared first-use timings. |
| `s1-regressions`, `s1-mlx-regressions` | Explicit installed llama/MLX lifecycle, cancellation, context isolation and complete long-input checks. |
| `s1-runtime`, `s1-cpu` | Current runtime/prefix or CPU cache comparisons against independent cleanup references. |
| `cleanup-quality`, `apple-speech-quality` | Independent cleanup facts/semantics or matching installed Apple speech locales and fresh sessions. |
| `cleanup-prompts`, `external-asr-quality` | Explicit local candidate runtimes/prompts or saved outputs scored against the shared manifest. |
| `model-switch` | Installed-model switching; also requires `RUN_MODEL_SWITCH_BENCHMARK=1`. |

`PIPELINE_BENCHMARK_S1_MODES` selects unique comma-separated current runtime
modes (`llama`, `llama-f16`, `mlx`, `mlx-uncached`). Prefer one runtime, one fixture
and one iteration for initial screening; an unset selection deliberately compares
all four in the explicitly selected `s1-runtime` group.

Model regression checks reuse one prepared engine for its preparation and recovery
assertions. `PIPELINE_BENCHMARK_MODEL` narrows that preparation sweep; the other
`asr-regressions` cases target the particular model implicated by their regression.
For S1 lifecycle checks, supply `S1_MINI_MODEL_PATH` (llama) or
`S1_MLX_MODEL_PATH` (MLX) explicitly; no temporary-path fallback or download is
attempted. The `cleanup` timing group can instead use the
app's validated installed S1 model.

```sh
S1_MINI_MODEL_PATH=/absolute/path/to/model.gguf \
  scripts/dev.sh benchmark --only s1-regressions

S1_MLX_MODEL_PATH=/absolute/path/to/mlx/package \
  scripts/dev.sh benchmark --only s1-mlx-regressions

PIPELINE_BENCHMARK_S1_MODES=mlx PIPELINE_BENCHMARK_FIXTURE=numbers-negation \
PIPELINE_BENCHMARK_ITERATIONS=1 \
  scripts/dev.sh benchmark --release --only s1-runtime

PIPELINE_BENCHMARK_MODEL=multilingual \
PIPELINE_BENCHMARK_FIXTURE=golden-en-boundaries \
PIPELINE_BENCHMARK_ITERATIONS=3 \
  scripts/dev.sh benchmark --release --only asr-quality

PIPELINE_BENCHMARK_MODEL=multilingual \
PIPELINE_BENCHMARK_FIXTURE=golden-nl-2 PIPELINE_BENCHMARK_ITERATIONS=1 \
  scripts/dev.sh benchmark --release --only asr-file

PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 PIPELINE_BENCHMARK_MODEL=multilingual \
  scripts/dev.sh benchmark --only model-setup
```

Use `PIPELINE_BENCHMARK_MODEL=all` only for a deliberate installed-model sweep.
Golden replay requires a fixture selection or `PIPELINE_BENCHMARK_GOLDEN=1`;
encoder comparisons additionally require `PIPELINE_BENCHMARK_ENCODER=1`.
`asr-file`, acoustic and candidate groups accept bounded comma-separated fixture
selections. Iteration limits and defaults vary by workload; most use three and
cap at ten. A three-sample nearest-rank p95 is just the slowest sample.

Downloads require `PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1` and an applicable group.
FluidAudio assets use the app's persistent `~/Library/Application Support/FluidAudio/Models`
cache. Apple locale installation uses the framework cache. `--only all` does not
supply download, external runtime, live-provider or model-switch opt-ins.
The command forwards selected environment settings to XCTest through Xcode's
`TEST_RUNNER_` convention.

Supplied audio uses `PIPELINE_BENCHMARK_AUDIO_PATH` and
`PIPELINE_BENCHMARK_REFERENCE_PATH` (16 kHz mono with an exact reference).
`PIPELINE_BENCHMARK_MAX_WER` optionally enforces an agreed accuracy threshold.
Bundled goldens choose WER/CER from their manifest and keep independent references,
licenses and hashes. Public fixture diagnostics may include transcripts; supplied
private audio/reference contents are not printed by the user-audio harness.

For Apple prompt comparisons, set `PIPELINE_BENCHMARK_CLEANUP_PROVIDER=apple`
and `PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH` to an external JSON array of
`{"id":"candidate-name","prompt":"cleanup instructions"}` objects, then run
`scripts/dev.sh benchmark --only cleanup-prompts`. An empty `prompt` exercises
the app's default. Each candidate uses the production Apple instructions,
guided result schema, greedy sampling, vocabulary and chunk planner. Candidate
order rotates across `PIPELINE_BENCHMARK_ITERATIONS`; language and exact fixture
filters use the existing benchmark settings. `APPLE_PROMPT_RESULT` JSON rows
include actual output, prompt/manifest hashes, semantic issues, lost facts,
reference error and latency. Save logs outside the checkout and inspect output
as well as scores before adopting a candidate. Reevaluation is needed when the
system model changes. The `cleanup-quality` group also tests recording delivery
with empty and whitespace-only prompts and no captured writing context.

`cloud-request` alternates direct PCM16 request encoding with the frozen array/Data/copy path and verifies every audio byte. `audio-conversion` prepares input buffers outside timers and tests 16/44.1/48 kHz capture plus owned file buffers. These checks capture no microphone and measure component work rather than end-to-end dictation.

## Read results correctly

Golden quality reports errors without an arbitrary universal model threshold.
Cleanup benchmarks report semantic misses, factual loss, fallback and latency
separately. Apple checks reject factual loss and failed cleanup, then verify that
the next prepared request cannot inherit prior data. Long-window checks preserve
record numbers and endings. Candidate protocol success alone does not establish
acceptable quality. See the [golden inventory](../Dictate%20AnywhereTests/Fixtures/Golden/README.md)
for provider selection, supported languages and explicit remote-provider setup.

The current overlay benchmark consumes preview suffix results for short/long
English and CJK text and reports median microseconds per call. It has no hardware
threshold or historical implementation loop. `OverlayContentTests` separately
runs in the ordinary suite and verifies observation dependencies, corrections,
Unicode boundaries and state transitions.

Record device, OS, model/SDK revisions, build configuration, iteration count and
trace setting alongside measurements. Repeat with `DICTATE_ANYWHERE_PERF_TRACE=0`
to estimate trace overhead. A first request after unload can still benefit from
OS file/shader caches. Live batch replay feeds audio without real-time sleeps;
whole-file replay excludes microphone/UI latency. XCTest CPU/memory metrics and
process counters exclude accelerator/helper allocations and do not establish
whole-app energy or peak system memory. Process CPU sums threads; process peak
RSS retains earlier cases' high-water marks. Use isolated processes for comparisons.

For optional integration checks, select the workload explicitly:

```sh
RUN_AUDIO_CAPTURE_SMOKE=1 scripts/dev.sh benchmark --only audio-hardware
DICTATE_CHROMIUM_CAPTURE_TESTS=1 scripts/dev.sh benchmark --only browser-context
DICTATE_ASSEMBLYAI_LIVE_TESTS=1 scripts/dev.sh benchmark --only live-insertion
```

Microphone stop/restart uses Debug and existing Dev-app microphone permission;
audio samples are discarded. Chromium uses an isolated disposable profile and
existing Accessibility permission. Live insertion uses the Dev app's configured
AssemblyAI credentials and Polished/context-sharing settings. Adding
`DICTATE_ASSEMBLYAI_LIVE_TESTS=1` to the browser workload enables its live-provider
path; `DICTATE_LIVE_CAPTURE_TESTS=1` enables native field capture in the live
insertion workload. Selecting `--only all` supplies none of these opt-ins.
Accessibility activation, target-app
paste latency, routing and live UI latency need real app traces or Instruments;
see the [tracing map](performance-tracing.md).

## Result storage

Keep raw outputs, benchmark JSON, logs, xcresult exports, dated evaluations and
PR/readiness notes outside the Git checkout. In the development workspace, use
an absolute path under workspace `docs/<topic>/`; elsewhere use a local output
directory outside the repo. Collector `--output` paths must follow the same rule.
Commit reusable collectors, independent golden references, licenses and input
hashes, not generated measurements. Record revisions and configuration alongside
local results. Project guides describe the current runtime and commands.

`--only s1-cpu` compares GGUF CPU KV precision. `--only s1-prepare`
compares unloaded and prepared first requests using the installed selected runtime.
The shared S1 stress references and saved-output scorer apply to any runtime.

`--only asr-language` compares unfiltered and script-filtered v3/Ultra output
through production file and live replay paths, using the shared human goldens.
It alternates ordering and records outputs, error, resource use and input hashes.
Select the model/fixture/iterations with the existing benchmark environment.

`asr-vocabulary` checks multilingual Nemotron's genuine names, absent terms,
cleared state, file recovery and live previews/finalization. It uses the normal
app cache and records first preparation separately from recognition latency.
`PIPELINE_BENCHMARK_NATIVE_VOCAB_WEIGHT` is benchmark-only and enables comparison
with documented SDK weights; it does not add a product setting.

`tdt-vocabulary` compares the previous similarity floors, short-token taper,
disabled acoustic rescue, 110M shared-head scoring, and prepared production
recordings. All variants use the same original token timestamps, references,
scorer and installed models. The live test changes terms during recording to
verify that Stop retains the recording's term snapshot. CTC/model downloads
are explicit; install assets with the existing model-download benchmark first.
Shared-head scoring reuses encoder weights, not TDT features from a single pass.
Compare cumulative peak RSS in separate processes; paired latency/CPU rows do
not establish memory or energy savings. Scripts and native language-name checks
retain rejected configurations for future SDK evaluations.

The `tdt-vocabulary` group also contains a separately opted-in auxiliary-head
installation check. Set `PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1` to validate the
application cache, cold targeted download, offline reuse and repair of a corrupt
local head. Temporary repair copies are discarded; the normal application cache
retains the installed head. No separate encoder is downloaded by this path.
