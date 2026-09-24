# Performance benchmarking

Run the repeatable benchmark suite from the repository root:

```sh
./scripts/dev.sh benchmark --release
```

The Release command uses native arm64, local Team ID development signing and
testable Release optimization. Run `./scripts/dev.sh signing TEAM_ID` once to
create the ignored local signing configuration. The default `benchmark` command
instead runs Debug and is useful for relative comparisons, not absolute
production latency. Repeat with `DICTATE_ANYWHERE_PERF_TRACE=0` to measure
instrumentation overhead. Preserve the device, OS, model revision, and build
configuration with results; the trace records device, OS, and build
configuration, while model revision must be recorded separately. The app and
dependencies are Release-optimized; Xcode compiles the XCTest benchmark
harness without optimization, so synthetic test-loop timings are not
production absolute timings.

The command runs the following deterministic or opt-in scenarios:

| Component | Coverage |
| --- | --- |
| Offline ASR | Replays the bundled speech fixture through installed Parakeet and available Apple Speech engines. |
| Pending audio workload | Models the non-streaming preview's repeated sample processing; no model inference or audio quality is measured. |
| Audio polling | Processes fixed sample windows and measures RMS/smoothing plus meaningful-display-change decisions. |
| Insertion preparation | Replays whitespace, list, CJK, and boundary fixtures through insertion formatting. |
| Paste script cache | Compares repeated AppleScript compilation with the cached preparation path. Compilation sends no keystrokes. |
| S1-mini policy | Exercises the startup-prewarm decision matrix. |
| S1-mini model load | Runs only when `S1_MINI_MODEL_PATH` points to an installed model. |

These benchmarks do not measure real Accessibility activation, target-app paste
latency, Core Audio or Bluetooth routing, or microphone startup. Those remain
covered by performance traces from live app runs. The offline ASR test skips
Parakeet when the selected model is not installed and skips Apple Speech when
its assets or authorization are unavailable. Each run reuses an engine across
iterations: it is not a cold-process/warm-model/warm-session matrix. The
printed per-iteration durations do not automatically report p50/p95, WER/CER,
CPU, memory, or energy; collect those separately before product decisions.
