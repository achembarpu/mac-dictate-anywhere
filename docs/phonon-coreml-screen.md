# Native Core ML Phonon-2 screen — 2026-10-03

Keep Phonon-2 out of the app for now. Its smaller installed cache is useful,
but short-clip speed matches existing models while read-speech accuracy trails
v3. The long-file gain is close to Ultra's, without a demonstrated quality win.
Retain the candidate collector, downloaded model and exact outputs for future work.

This is distinct from the earlier Fermion MLX experiment. The pinned FluidAudio
0.17.5 already supports the author's five-value Core ML conversion, same v3
decoder and English tokenizer. Use its official sparse encoder with the Neural
Engine. The [SDK guide](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/Phonon2.md)
documents macOS 15 minimum and expensive sparse GPU materialization. That GPU
path and slower per-row encoders were pruned before adding this screen. No new
dependency, app model choice, runtime default or processor control is added.

## Results

Same shared Swift WER scorer, production ASR config and fresh decoder state per
file. Signed optimized Release harness, M3 Max/36 GiB/macOS 26.7.1. Serial grouped
runs, one shape warmup outside timer, three trials. All 135 native outputs are
deterministic across trials. First model preparation is 78.65 s including download,
first Core ML compilation and manager warmup; it is not an isolated compile time.
Later preparation uses existing OS caches. Models are in the normal persistent
SDK app cache, not a benchmark copy.

| English coverage | v3 | Ultra | Phonon-2 |
| --- | ---: | ---: | ---: |
| Nine readings / 224 words: WER | 5.36% | 5.80% | 8.93% |
| Sum of reading p50 times | 660.0 ms | 664.3 ms | 666.5 ms |
| Three meeting utterances / 126 words: raw WER | 6.35% | 13.49% | 7.14% |
| Sum of meeting p50 times | 294.2 ms | 292.1 ms | 291.1 ms |
| 72.665 s constructed file: WER | 4.02% | 5.75% | 5.75% |
| Constructed file p50 | 327.2 ms | 228.9 ms | 221.4 ms |
| Installed cache file size | 460.9 MiB | 603.0 MiB | 341.2 MiB |

Phonon-2's long-file time is 32% lower than v3 and only about 3% lower than
Ultra. Small grouped timing differences are inconclusive. Model cache bytes
are file sizes, not resident RAM. Process CPU/RSS omit Core ML helpers and
accelerators, so neither memory efficiency nor energy is established.

Meeting WER needs interpretation: Ultra omits some fillers/repetitions and
writes “25”; the exact reference preserves “twenty five.” Those are distinct
from the quiet male utterance's lost negative clause, which all three models
get wrong. Phonon-2 is not a demonstrated semantic-quality upgrade. Its PCM16
quiet control is 105.88% WER versus v3's 70.59%; noisy/quiet derived controls
and the long composite are reported separately, not pooled with independent
utterances. This is a regression inventory, not population WER evidence.

## New references and input-gain follow-up

Three AMI clips add two speakers from a spontaneous role-play design meeting:
fillers/repeated words and duration, negation/question, names/self-correction.
References come directly from human word annotations. Exact PCM16 crops preserve
original samples. Source licences, download hashes, channel mapping, annotation
IDs and crop samples are in the golden provenance. The extractor verifies pinned
sources and lexical bounds; no ASR generated or corrected the references.
These clips share a room/session and two share a speaker. Headset crosstalk may
be present; references target the annotated speaker. They complement the read
speech and synthetic acoustic controls, not every live microphone condition.

Six focused v3 raw-sample outputs compare source vs peak-capped gain4 on the
quiet male clip (RMS 0.00113085, peak 0.01355). WER improves 22.58% -> 9.68%,
but “didn't get anything else” still becomes “And get anything else?” The boost
restores the final question, not the negative clause. Keep it research-only
pending live/VAD/natural-noise and broader-speaker checks. Transform/hash costs
are outside timers; these grouped trials do not prove a gain speedup.

## Reproduce

```sh
PIPELINE_BENCHMARK_MODEL=phonon2 PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 \
  PIPELINE_BENCHMARK_ITERATIONS=3 DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only asr-candidates

PIPELINE_BENCHMARK_MODEL=multilingual \
  PIPELINE_BENCHMARK_FIXTURE=golden-en-ami-1,golden-en-ami-2,golden-en-ami-3 \
  DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only asr-candidates

PIPELINE_BENCHMARK_MODEL=multilingual PIPELINE_BENCHMARK_FIXTURE=golden-en-ami-2 \
  PIPELINE_BENCHMARK_ACOUSTIC_VARIANTS=reference-pcm16,reference-gain4 \
  DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only asr-acoustics
```

Only `asr-candidates` accepts comma-separated fixture IDs. Select one of
`phonon2`, `multilingual`, `multilingualUltra`. The Phonon screen skips on Intel
and macOS 14; product Intel support remains the existing runtime. Only an explicit
download flag permits SDK download. Cached-only runs load local files directly,
avoiding automatic SDK redownload/recovery. No audio uploads or microphone use.

[Structured evidence](benchmarks/phonon-coreml-screen-2026-10-03.json) retains all
135 native and six gain outputs, per-fixture medians, source/model/fixture/log
hashes, cache sizes and process resources. It retains both inventory hashes;
new metadata/selection guards do not change the measured decode boundaries.
