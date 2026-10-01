# Model-aware transcription verification

The final paired probes improve aggregate final error and reduce recognition
work by 49–60%. V2 intentionally spends more time at Stop to preserve clear
speech lost by the SDK overlap decoder.

| Model / metric | Mean final error | Mean recognition work | Mean Stop work |
| --- | ---: | ---: | ---: |
| Parakeet v3 (WER) | 7.47% → 5.56% | 14.55 → 5.87 s | 80.3 → 69.1 ms |
| Parakeet v2 (WER) | 3.64% → 3.26% | 10.89 → 4.97 s | 60.7 → 187.3 ms |
| 110M (WER) | 7.66% → 5.75% | 5.56 → 2.81 s | 32.3 → 34.2 ms |
| SenseVoice (CER) | 17.95% → 0.00% | 1.49 → 0.74 s | 69.4 → 25.8 ms |

Measured on 2026-10-02: Mac15,10, macOS 26.7, Team-signed Release app and XCTest
harness compiled with `-O`, FluidAudio 0.17.5 and the same installed weights per
pair. The parent reference uses the old 30/20-second commits, 500 ms previews,
silence checks and longest-text final choice with the updated SDK. It does not
isolate dependency-update speedups. Three runs alternate order and prepend
0/500/1000 ms silence. English uses the 72.665 s composite; Mandarin uses the
repeated 37.44 s composite. No real-time sleeps or microphone capture.

V2 adds about 127 ms at Stop on the English composite. The 110M Stop difference
is about 2 ms. Some individual shifted English trials worsen even though mean
WER improves; keep the per-trial evidence. These probes are not population WER
or live UI latency measurements.

## Quality and configuration checks

- All 90 supported model/fixture cases across ten ASR choices passed three
  repeats: 270 decodes, all nonempty. Compared with the pre-upgrade matrix, 78
  existing cases retain identical errors and v2's boundary case improves.
  Unsupported language/model combinations are excluded explicitly.
- Quiet Dutch is zero WER for v3, Ultra and multilingual Nemotron. Quiet
  non-speech, silence, fresh sessions, short tails, cancellation, and shifted
  v2 vocabulary seams have separate production-path regression checks.
- ANE/GPU comparison: all 11 supported goldens match errors for both v3 and
  Ultra. Warm GPU inference is slower locally, so keep ANE. First GPU use can
  compile. That earlier encoder-only audit used an unoptimized test harness;
  app/SDK inference was Release-optimized. Do not compare its absolute timing
  with the final optimized-harness policy table.
- Ultra's local English results are mixed, while the German case improves.
  Retain v3 selections/default and expose Ultra explicitly. Do not rank models
  from this small inventory, which includes a shared English speaker and
  artificial concatenations. Multilingual Nemotron's artificial language-switch
  clip remains difficult (66.4% CER); SenseVoice is the stronger Mandarin option.
- S1-mini's real model tests cover short corrections, numbers, time and dates,
  all 110 invoice IDs across long-input handling, and a varied long transcript's
  final Friday-to-Thursday correction. Short warm benchmark p50 is 85.6 ms.
  Repetitive long fixtures reach the output budget and return the whole original
  text; their ~1 s / ~6.7 s timings are fallback costs, not successful cleanup.
  `cleanup.request` records `output_limit_fallback` explicitly.
- The latest checked S1-mini Q4_K_M weight checksum matches the pinned download
  despite a newer repository documentation revision. llama.swift 2.10549.0 is
  already the latest published wrapper tag; no unnecessary weight redownload
  or wrapper upgrade.

## Verification and reproduction

Final full signed Debug suite with installed-model, Mandarin, Nemotron and S1-mini
opt-ins: **579 total; 540 passed, 39 skipped, 0 failed**. App Swift warnings are
errors. Focused-group/forwarding script tests and diff whitespace checks pass.
Skips include unavailable platform/hardware and opt-in benchmark/network cases.
No cloud accuracy, energy, microphone/Bluetooth-route latency, or whole-app peak
memory claim.

The [machine-readable report](benchmarks/model-aware-transcription-2026-10-02.json)
retains per-trial comparisons, all quality cases, source hashes, installed weight
hashes, SDK pins and measurement limits. The containing commit provides the
source snapshot. Fixtures and licensing are in the
[golden inventory](../Dictate%20AnywhereTests/Fixtures/Golden/README.md).

```sh
# Use an isolated stable build directory and ignored local Team signing.
DERIVED_DATA_PATH="$PWD/DerivedData" \
PIPELINE_BENCHMARK_MODEL=multilingual \
PIPELINE_BENCHMARK_FIXTURE=golden-en-boundaries \
scripts/dev.sh benchmark --release --only asr-quality

DERIVED_DATA_PATH="$PWD/DerivedData" \
PIPELINE_BENCHMARK_MODEL=all PIPELINE_BENCHMARK_GOLDEN=1 \
scripts/dev.sh benchmark --release --only asr-quality

DERIVED_DATA_PATH="$PWD/DerivedData" \
scripts/dev.sh benchmark --release --only cleanup
```

See [model policies and primary sources](model-aware-transcription.md) and the
[shared benchmark documentation](performance-benchmarking.md) for other models,
encoder comparisons, explicit app-cache downloads, external fixtures and traces.
