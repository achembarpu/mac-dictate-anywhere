# Performance benchmarking

Run the repeatable benchmark suite from the repository root:

```sh
./scripts/dev.sh benchmark
```

The command runs the following deterministic or opt-in scenarios:

| Component | Coverage |
| --- | --- |
| Offline ASR | Replays the bundled speech fixture through installed Parakeet and available Apple Speech engines. |
| Audio polling | Processes fixed sample windows and measures RMS/smoothing plus meaningful-display-change decisions. |
| Insertion preparation | Replays whitespace, list, CJK, and boundary fixtures through insertion formatting. |
| Paste script cache | Compares repeated AppleScript compilation with the cached preparation path. Compilation sends no keystrokes. |
| S1-mini policy | Exercises the startup-prewarm decision matrix. |
| S1-mini model load | Runs only when `S1_MINI_MODEL_PATH` points to an installed model. |

These benchmarks do not measure real Accessibility activation, target-app paste
latency, Core Audio or Bluetooth routing, or microphone startup. Those remain
covered by performance traces from live app runs.
