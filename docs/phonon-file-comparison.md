# Phonon-2 against installed speech models

The app has no Phonon backend, so this evaluation does not change application
performance. The compact model is competitive with native Parakeet throughput;
its published size/speed claims do not establish a universal replacement.

Measured on M3 Max/36 GiB/macOS 26.7.1. All models decode the same seven English
goldens (144.13 seconds total), with three warm trials after an untimed first
decode of each complete-file shape. Native app and XCTest are optimized Release
with local Team ID signing. Native uses the production recording-file path;
Phonon uses Fermion 0.2.7's full file wrapper, including reading/resampling and
segmentation, with the author default `tdt16,dense16`. No simultaneous inference
or live previews. The shared Swift scorer computes every WER below.

| Model | Sum of seven fixture medians | 72.67 s boundary clip | Boundary WER |
| --- | ---: | ---: | ---: |
| Parakeet v3 | 0.799 s | 0.327 s | 4.02% |
| Parakeet Ultra | 0.707 s | 0.241 s | 5.75% |
| Parakeet v2 | 0.576 s | 0.191 s | 3.45% |
| Parakeet 110M | 0.290 s | 0.093 s | 6.90% |
| Parakeet EOU 320 ms | 4.199 s | 2.153 s | 6.32% |
| Nemotron 560 ms | 3.969 s | 1.985 s | 5.17% |
| Nemotron 1120 ms | 2.434 s | 1.177 s | 5.75% |
| Nemotron 2240 ms | 1.792 s | 0.860 s | 5.17% |
| SenseVoice | 0.631 s | 0.341 s | 8.05% |
| Multilingual Nemotron | 3.520 s | 1.840 s | 9.20% |
| Phonon-2 | 0.707 s | 0.329 s | 5.17% |

Phonon takes about 12% less time than v3 across the sum of these fixture medians,
essentially equal to Ultra in that aggregate and to v3 on the boundary clip.
V2, 110M and SenseVoice take less aggregate time. Phonon has substantially higher
file throughput than the EOU/Nemotron streaming paths, whose principal goal is
incremental response during recording. This cannot predict their first-partial
latency or the user's time after Stop.

The complete-file comparison is fairer than comparing Phonon's one-shot decode
against repeated native live previews. The pipelines still have different
segmentation and frameworks, and model runs are grouped rather than interleaved
across processes. Ratios describe this small inventory on this Mac. Boundary WER
is not population WER or proof of all-model quality superiority. Refer to the
retained per-fixture rows when selecting a model.

Phonon retains the earlier accuracy pattern: one English case improves versus
v3, two worsen, four match. Default peak MLX memory remains about 1.92 GB despite
the 164 MB archive. Its strongest product case is a small English download, not
an established overall latency/accuracy win. Native packaging, streaming,
vocabulary biasing and cancellation still require a separate backend integration.

[All 210 native and 21 Phonon trials, outputs, source hashes and configuration](benchmarks/phonon-file-comparison-2026-10-02.json)
are committed. Reproduce native runs with installed app-cache models:

```sh
DERIVED_DATA_PATH="$PWD/DerivedData" PIPELINE_BENCHMARK_MODEL=all \
  PIPELINE_BENCHMARK_LANGUAGES=en PIPELINE_BENCHMARK_ITERATIONS=3 \
  scripts/dev.sh benchmark --release --only asr-file
```

Collect Phonon with `scripts/evaluate_phonon.py --model-path PATH --iterations 3
--output RESULTS.json` in the pinned research environment. Score the saved
outputs with `PIPELINE_BENCHMARK_ASR_RESULTS_PATH=RESULTS.json scripts/dev.sh
benchmark --release --only external-asr-quality`. The harness verifies the
golden audio checksum and manifest; it downloads/starts no models or servers.
