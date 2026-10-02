# Performance benchmarking

## Audio capture hardware check

After configuring local Team ID signing, run `RUN_AUDIO_CAPTURE_SMOKE=1 scripts/dev.sh test`
to include three rapid microphone stop/restart cycles. This check uses real
capture controllers and different setup queues through the shared restart gate.
It counts callbacks and discards audio samples. It requires microphone permission
already granted to the Debug app and skips without prompting when permission is
unavailable. Normal test runs skip this hardware check. Full dictation checks on
speaker and Bluetooth/headphone routes remain useful for output restoration and
recognizer-level engine switching.

Run the repeatable benchmark suite from the repository root:

```sh
./scripts/dev.sh benchmark --release
```

The Release command targets the host's native macOS architecture (arm64 on
Apple Silicon, x86_64 on Intel) with local Team ID development signing and
testable Release optimization. Run `./scripts/dev.sh signing TEAM_ID` once to
create the ignored local signing configuration. The default `benchmark` command
instead runs Debug and is useful for relative comparisons, not absolute
production latency. Repeat with `DICTATE_ANYWHERE_PERF_TRACE=0` to measure
instrumentation overhead. Preserve the device, OS, model revision, and build
configuration with results; local Release benchmarks trace by default even
though distributed Release archives do not. The trace records device, OS, and
build configuration, while model revision must be recorded separately. The app and
dependencies are Release-optimized; benchmark runs also compile the XCTest
harness with `-O`. Synthetic test-loop timings still exclude full app rendering
and are not production absolute timings.

The command runs the following deterministic or opt-in scenarios:

Use registered groups to run focused benchmarks:

```sh
./scripts/dev.sh benchmark --list
./scripts/dev.sh benchmark --only overlay
./scripts/dev.sh benchmark --release --only audio,overlay
./scripts/dev.sh benchmark --only insertion --only recovery
```

`--only` accepts comma-separated groups and can be repeated. Repeated groups
are deduplicated. The default is `all`; unknown or empty groups fail before
building. Groups are registered with their descriptions and Xcode test
selectors in one catalog in `scripts/dev.sh`. Add new benchmark selectors
there to make them available through `--list` and focused runs. Use
`--only asr-quality` for golden quality, paired policies, model setup and encoder
comparisons; `--only cleanup` runs the local cleanup checks. `--only cleanup-quality`
runs the authored cleanup references and paired Apple/context-window checks;
`--only apple-speech-quality` tests installed Apple locale assets with fresh
prepared sessions. See the golden inventory for provider/model selection and
explicit billable-provider opt-in. Benchmarks
compile both app and tests with `-O` for consistent helper comparisons.

`--only s1-context` compares fresh and reused S1 allocations on identical cleanup
goldens. `--only asr-file` runs complete golden files through installed native
speech models without live previews; select models, fixture, language and repeats
with the existing `PIPELINE_BENCHMARK_*` settings. Saved external speech outputs
can be checked with `PIPELINE_BENCHMARK_ASR_RESULTS_PATH` and
`--only external-asr-quality`; the manifest hash must match the bundled inventory.
See [S1 context reuse](s1-context-reuse.md) and
[Phonon file comparison](phonon-file-comparison.md) for measurements and limits.
The standalone [native MLX probe](../tools/s1-mlx-probe/README.md) and
`scripts/evaluate_s1_mlx.py` collect S1 outputs for the existing
`PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH` / `--only cleanup-prompts` scorer.
They do not change the app's runtime or download models implicitly.

`--only asr-acoustics` separates quiet Float32 input from PCM16 quantization
using one installed TDT model. It preserves the golden reference, tests
peak-capped gains and synthetic silence/noise controls, and records raw outputs,
shared error scores, input hashes/RMS/peaks and process CPU/RSS. This is research
only; transforms are outside decode timers and product audio is unchanged.
See [the acoustic screen](tdt-acoustic-screen.md) for selection and limitations.

The pending-audio workload shares the production preview predicate and 15-second
preview bound. Its 60-second speech simulation requests 60 previews, including
the initial 500 ms guess; it counts SDK overlap windows and the final flush too.
It compares this work against the parent's 120 previews and 31,840,000 pending
samples. This overlap count applies to v3-family/110M finalization; v2 uses a
whole-recording batch finalizer. Counts describe scheduled audio work, not CPU
time or transcript quality.

| Component | Coverage |
| --- | --- |
| Offline ASR | Replays the bundled speech fixture through installed Parakeet and available Apple Speech engines. Reports latency, duration, median real-time factor, and beginning/end recognition sentinels. |
| Mandarin ASR quality | Replays the four bundled, referenced Mandarin fixtures through installed SenseVoice. Reports CER and per-fixture p50/p95; skips if the model is not installed. |
| User audio quality | If both `PIPELINE_BENCHMARK_AUDIO_PATH` and `PIPELINE_BENCHMARK_REFERENCE_PATH` are provided, replays a local 16 kHz mono fixture and reports WER. No audio or reference content is uploaded or logged by the harness. |
| Pending audio workload | Counts bounded previews and authoritative overlap windows against the parent workload; no model inference or audio quality is measured. |
| Model policy comparison | With `PIPELINE_BENCHMARK_FIXTURE` or external audio/reference paths and an installed batch model, alternates parent/candidate order and shifts seams. Reports WER/CER, total processing time, Stop time and first-visible audio position using production candidate paths. Gates mean error and total time against the parent policy. |
| Golden human speech | Opt in with `PIPELINE_BENCHMARK_GOLDEN=1` or select `PIPELINE_BENCHMARK_FIXTURE`. Replays bundled human English, Mandarin, Dutch, German and derived boundary/language-switch cases. Uses live batch iteration/Stop or native streaming recovery. Reports per-model/fixture error and timing; missing models and unsupported languages skip. |
| Encoder placement | Opt in with `PIPELINE_BENCHMARK_ENCODER=1` and `multilingual` or `multilingualUltra`. Alternates ANE/GPU order on the supported golden clips and reports exact errors and per-trial decode times. First-use compilation is visible; compare warm trials separately. |
| Audio polling | Processes fixed sample windows and measures RMS/smoothing plus meaningful-display-change decisions. |
| PCM buffer creation | Repeatedly calls the app's 4096-frame 16 kHz buffer builder. XCTest records clock, CPU, and memory metrics. |
| Cloud request encoding | Converts 60 s of synthetic samples to PCM16 and builds AssemblyAI's multipart body, without network access. XCTest records clock, CPU, and memory. |
| Recovery I/O | Enqueues 30 s of synthetic audio through the real recovery writer, preserves it, reloads, and reads bounded chunks. Reports save and read p50/p95. |
| Long transcript | Joins 300 disjoint transcript segments and normalizes the result. XCTest records clock, CPU, and memory. |
| Insertion preparation | Replays whitespace, list, CJK, and boundary fixtures through insertion formatting. |
| Paste script compilation | Compares repeated AppleScript compilation with the production precompile and cached path, without sending keystrokes. |
| S1-mini policy | Exercises the production startup-prewarm decision matrix. |
| S1-mini preparation | Measures production weight loading plus one synthetic inference warmup with the app's validated installed model, or an explicit `S1_MINI_MODEL_PATH`; never downloads. Already-warm models skip synthetic inference. |
| S1-mini cleanup | With the app's validated installed model, or `S1_MINI_MODEL_PATH`, runs short, long and over-limit text through the real local cleanup service and reports cold/warm request timings. |
| Apple Intelligence cleanup | Runs a fixed cleanup prompt through the on-device Foundation Models service when available. Guided decoding and planning are visible in performance traces. |
| Cleanup golden quality | Eleven authored English/German/Chinese/Dutch references check numbers, negation, questions, self-corrections and long endings. Apple is paired with the frozen production baseline; other providers require explicit selection. Reports semantic misses, required facts, original fallback, reference error and latency separately. |
| Apple Speech golden quality | Replays matching installed locales through two fresh production SpeechAnalyzer sessions, recording preparation, final decode and WER/CER. Asset installation requires explicit `PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1`; framework asset failures are reported as skips. |
| External cleanup prompts | With an explicit local prompt file and Ollama model, compares verbatim candidate instructions with the app's production prompt on the same weights. Reports required facts and semantic misses independently of protocol completion. Can also score saved model outputs against the exact shared manifest hash. |
| External speech runtime | With an explicit loopback OpenAI-compatible STT endpoint and model, replays the same licensed speech goldens and WER/CER scorer. Starts no server and downloads no model implicitly. |
| Model switching | With `RUN_MODEL_SWITCH_BENCHMARK=1` and at least two installed models, times a fixed model-switch sequence. |

Set `PIPELINE_BENCHMARK_MODEL=all` to sweep models already installed on this
Mac; the default is `parakeetEou320`. Ordinary benchmark runs do not download
models. Explicitly set `PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1` to run the app's
downloader for the selected model(s) first. Downloads go into the persistent
`~/Library/Application Support/FluidAudio/Models` cache used by the app; this is
not a separate benchmark cache. With `PIPELINE_BENCHMARK_MODEL=all`, the setup
step installs each local model supported by the host. It can require several GB.
The benchmark command forwards the documented environment variables to the
XCTest host using Xcode's `TEST_RUNNER_` convention
([Xcode 13 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-13-release-notes));
setting them on a bare `xcodebuild` invocation does not have the same effect.
Use `PIPELINE_BENCHMARK_ITERATIONS=5` for longer runs (default 3), and save the
`.xcresult` bundle for XCTest's per-iteration CPU/memory/clock measurements.
For a meaningful offline ASR p95 comparison, use at least 20 iterations; with
three samples, nearest-rank p95 is simply the slowest observation. The workload
tests cap their iteration count at 10, so their p95 values are exploratory.
S1-mini's first request after unload measures model initialization, but the
operating system's file and Metal shader caches may already be warm; restart
the test host for a truly cold-process comparison.
FluidAudio is pinned to 0.17.5; llama.swift is pinned to 2.10549.0. SDK speech
debug logging is disabled unless explicitly enabled in a local Debug build.
Use a separate stable `DERIVED_DATA_PATH` for each worktree to avoid sharing
Xcode build products.

The [hardware defaults and optimized encoder evidence](model-hardware-defaults.md)
record which execution paths the app chooses internally. Hardware comparisons
remain developer benchmarks; the app has no processor tuning workflow or
startup calibration. The latest comparison uses five paired repeats with both
app and harness optimized, retaining first-use and warm trials separately.

The bundled [golden reference inventory](../Dictate%20AnywhereTests/Fixtures/Golden/README.md)
includes exact references, license, source IDs, hashes and reproduction commands.
For example, select `PIPELINE_BENCHMARK_MODEL=multilingual` and
`PIPELINE_BENCHMARK_FIXTURE=golden-en-boundaries` for the paired TDT comparison;
select `senseVoice` and `golden-zh-boundaries` for pause segmentation. The paired
comparison replays 500 ms blocks without real-time sleeps. Its total time measures
recognition work, and its Stop time measures the remaining flush; neither measures
real microphone UI latency. The parent reference implementation retains the old
30/20-second commit policy, 500 ms previews and longest-text final choice.
Default paired runs shift seams by 0, 500 and 1000 ms, alternate execution order,
and report mean error/time; these are small regression probes, not population WER.
If a bundled public golden regresses, the paired harness prints both final
transcripts for that trial to help locate the failed seam. External recordings
never have their transcript or reference printed by the harness.
First-visible audio position is the amount fed when text appears, not wall-clock
user latency. Golden quality inventory uses the manifest's supported languages
and WER/CER metric, and deliberately has no uncalibrated model-independent gate.

The `cleanup-prompts` and `external-asr-quality` groups are research tools.
See [candidate evaluation and reproduction](model-candidate-evaluation.md) for
explicit prompt/model/result-file selection. The default benchmark run skips
these groups unless their corresponding environment variables are supplied.
Candidate quality misses remain visible even when the protocol completed;
test success does not establish that a model is safe to adopt. Only bundled
public/audio and independently authored text fixtures can have diagnostic
transcripts printed. A runtime's missing or unreliable truncation metadata must
not be mistaken for proof of transcript completeness.

When supplying your own audio, optionally set `PIPELINE_BENCHMARK_MAX_WER=0.3`
to enforce an agreed WER gate for the user audio benchmark. The paired comparison
also accepts `PIPELINE_BENCHMARK_METRIC=cer` for external Mandarin references;
external paths default to WER. Bundled human recordings supplement the existing
synthetic Mandarin recordings. Keep separately sourced fixtures' licenses and
provenance with them.

These benchmarks do not measure real Accessibility activation, target-app paste
latency, Core Audio or Bluetooth routing, or microphone startup. Those remain
covered by performance traces from live app runs. The offline ASR test skips
Parakeet when the selected model is not installed and skips Apple Speech when
its assets or authorization are unavailable. Each run reuses an engine across
iterations: it is not a cold-process/warm-model/warm-session matrix. The
offline ASR and recovery timings report p50/p95, and XCTest records CPU/memory
for the synchronous workload tests. These are not whole-app CPU or peak-memory
measurements. Energy, thermal state, microphone callback overruns, and live UI
latency still require Instruments and real app runs before product decisions.

`OverlayContentTests` always runs in the normal test suite. It evaluates the
production preview and waveform bodies under Observation tracking and proves
that 600 level-only updates cause zero transcript-content invalidations. It
also covers preview disabled, same-length corrections, empty/resumed text, and
character-boundary/Unicode output. These are dependency checks rather than
counts of frames rendered by SwiftUI.

Run the focused overlay comparison after configuring local Team ID signing:

```sh
./scripts/dev.sh benchmark --only overlay
```

This command runs the dependency checks and compares the production bounded
suffix helper with the historical full-count algorithm on identical short/long
English and long CJK text. It compiles **both** the Debug app and test target
with `SWIFT_OPTIMIZATION_LEVEL=-O`. It alternates measurement order, consumes results, checks matching
output, and reports median microseconds per call over five rounds. Timings have
no pass/fail threshold. The separate `DictateAnywhere-Benchmark.xcresult` bundle
preserves the normal test result bundle. These optimized Debug helper timings
do not measure whole-app CPU, UI frames, or energy use.

XCTest performance tests run one unrecorded warm-up plus the configured
measurement iterations ([Apple documentation](https://developer.apple.com/documentation/xctest/xctmeasureoptions/iterationcount)).
XCTest memory metrics measure memory change during the block, not the app's
high-water mark ([Apple documentation](https://developer.apple.com/documentation/xctest/xctmemorymetric)).

## Bounded Whistle screens and process resources

[Whistle evaluation](whistle-evaluation.md) uses the existing `asr-file` and
`external-asr-quality` groups with the expanded 20-pair golden inventory.
`scripts/evaluate_whistle.py` selects local pinned assets and accepts repeated
`--fixture ID` filters; it never starts a server or downloads weights. Skip
unsupported languages and audio beyond the native 30-second limit explicitly.
Use a single pass to screen candidates; repeat only useful finalists.

`ASR_FILE_RESULT` now includes per-request process CPU milliseconds and cumulative
process peak RSS bytes. CPU time sums threads and can exceed wall time; it
excludes Core ML helpers and accelerator work. Process RSS excludes helper/GPU/ANE
allocations, includes the app/test harness, and retains the peak of earlier cases.
Use isolated processes for memory comparisons, and never label these counters
as total model/system RAM or energy. `ASR_SAVED_RESULT` emits structured shared
WER/CER scores, preserving candidate output and iteration identity.
