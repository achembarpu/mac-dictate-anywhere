# Whistle: small CPU STT screening

Whistle is a useful size/speed candidate, with an accuracy cost in this small
inventory. Keep the current speech defaults. It is an evaluation runtime, not a
new app backend. Its strongest observed advantages are its 16.9 MB archive,
short CPU calls, and much better preservation of one quiet acoustic control.

M3 Max, 36 GiB, macOS 26.7.1, 2026-10-02/03. The existing benchmark setup scores
the same licensed audio/text pairs through the shared Swift WER implementation.
Native app/XCTest use optimized Release and local Team signing. Whistle uses
the official CPU C API through cactus-needle 3.1.0; file reading and PCM decoding
are included in its warm timer. Shapes are exercised once outside warm timing.
Models run serially. Their grouped timings are screening evidence, not a
controlled interleaved speedup estimate or live Stop latency.

## Accuracy and decode work

These aggregate scores exclude the correlated quiet/noise controls and the
72-second constructed composite. English has nine independent clips/224 words;
Dutch and German each have two clips/39 words. WER is total word edits divided
by total reference words. Timing sums each clip's median for three-repeat paths;
Ultra/110M have only one screening pass, so their times are provisional.

| Model | English WER / summed time | Dutch WER / time | German WER / time |
| --- | --- | --- | --- |
| Whistle, supplied language | 14.73% / 0.485 s | 12.82% / 0.070 s | 23.08% / 0.114 s |
| Parakeet v3 | 5.36% / 0.658 s | 2.56% / 0.118 s | 5.13% / 0.179 s |
| Parakeet Ultra, one pass | 5.80% / 0.683 s | 2.56% / 0.124 s | 0% / 0.178 s |
| Parakeet 110M, one pass | 6.70% / 0.311 s | Unsupported | Unsupported |

All 45 supplied-language Whistle calls returned successfully; 15 additional auto-language
outputs were exactly equal. Keep the author's automatic language detection as
the starting recipe; no benefit from language forcing appeared here. Whistle
short calls span roughly 22–62 ms; the29.4-second reading takes 170 ms. It makes
real name/word mistakes. Reference WER also penalizes valid number formatting
and abbreviations; it is not a complete semantic quality judgment.

## Quiet speech, memory and limitations

The new percentage/negation clip has the same reference in normal, quiet and
10 dB white-noise versions. Quiet is a 20 dB amplitude reduction, not silence
trimming. This exposes a decoder failure after speech eligibility: v3's complete
file path does not use the old volume gate, yet its quiet output loses/changes
most of the utterance. Ultra/110M also regress. Whistle retains the utterance
with the same 17.65% reference WER as the normal/noisy versions. V3 is 11.76% on
normal/noisy and 70.59% quiet. Investigate input/log-mel normalization with this
small paired probe before broad new model runs. Do not alter the golden text.

Whistle's forced-language process peak RSS is 142,376,960 bytes (135.8MiB), including
Python/numpy/soundfile and native inference. The first six-case exploratory peak
was113.3MiB; these are different process workloads. Process CPU time sums every
thread, so it can exceed wall time. Native resource rows describe the app/test
process only: CoreML helpers and accelerator allocations are excluded. Neither
process RSS nor CPU time proves lower total system RAM or energy use.

Silence and seeded steady white noise return empty text.480,001 samples produce
the documented 30-second limit error. The collector skips the 72.67-second
composite rather than scoring a truncated prefix. This means Whistle has no
long-file result in this screen. No prompt/beam/quant/depth tuning is claimed:
the public C API supplies fixed native decoding defaults, while the CLI has
thread and decoder-depth flags. Smaller depths are not advanced while default
quality already trails the native alternatives.

Native adoption still needs lossless longer-audio handling, cancellation,
model ownership/unload, vocabulary tests and arm64/Intel packaging. The reviewed
C API is process-global and not thread-safe, with no streaming or destruction
entry point. Published Python wheels include both Mac architectures; this does
not prove Intel app performance. Keep Whistle on the research shortlist for
small-download/CPU use, rather than adding it to the main model picker yet.

## Reproduce and reuse

Use a research environment with cactus-needle 3.1.0,numpy 2.3.3 and soundfile 0.13.1.
Download explicitly from these immutable sources; no runtime/model starts or
downloads implicitly in the collector:

- [Whistle weights](https://huggingface.co/Cactus-Compute/whistle/tree/b358ddadd89b7a713b5aa131f23032d3cca1b251):
  `whistle.cact`, 16,919,407 bytes, SHA256
  `b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb`.
- [Native engine wheel](https://huggingface.co/Cactus-Compute/needle3/tree/c7c415a3d1b3d929014bc6e866d51ebb971f7089/python):
  `cactus_needle-3.1.0-py3-none-macosx_11_0_arm64.whl`, extract
  `needle/libneedle3.dylib`. Wheel SHA256
  `ad1cba80ede4c058692370964eec4d881a1fdc80014f7210b2d13891bad7d1c6`.

```sh
python scripts/evaluate_whistle.py --model-path /path/whistle.cact \
  --library-path /path/libneedle3.dylib --iterations 3 \
  --detect-language --output /tmp/whistle.json

PIPELINE_BENCHMARK_ASR_RESULTS_PATH=/tmp/whistle.json \
  scripts/dev.sh benchmark --release --only external-asr-quality

PIPELINE_BENCHMARK_MODEL=multilingual PIPELINE_BENCHMARK_LANGUAGES=en,nl,de \
  PIPELINE_BENCHMARK_ITERATIONS=3 \
  scripts/dev.sh benchmark --release --only asr-file
```

Repeat `--fixture ID` to restrict Whistle before expanding a screen. The collector
uses soundfile float32 decoding; the reviewed package's own WAV reader treats
32-bit WAV data as integers, which would misread the existing float composite.
It disables package telemetry and selects an explicit local library. All fixture
and model/library hashes are retained.

[Structured evidence](benchmarks/whistle-screen-2026-10-03.json) includes 60 Whistle
and 76 native outputs, resource rows, scored errors, dependencies, model/source/log
hashes and all fixture selections. Signed Debug: 637 tests, 564 passed, 73 skipped,
zero failures; focused Release scorer and native file checks passed. Skips are
explicit benchmark/model opt-ins, not successful model decodes.

The fixture inventory now has 20 pairs: 15 existing, three new English FLEURS readings,
and two derived acoustic controls. All source references remain independent of
ASR. See [attribution and transformations](../Dictate%20AnywhereTests/Fixtures/Golden/README.md).
The workspace `docs/stt-runtime-research.md` tracks dependency/other-model
research and the pruned matrix; the full follow-up remains active.

Primary contracts: [Whistle model card](https://huggingface.co/Cactus-Compute/whistle),
[official runtime](https://github.com/cactus-compute/needle),
[pinned native header](https://huggingface.co/Cactus-Compute/needle3/blob/c7c415a3d1b3d929014bc6e866d51ebb971f7089/macos-arm64/needle.h).

The reviewed Whistle C API does not expose EOS/completion or truncation metadata.
Successful calls above therefore establish returned text, not an explicit decoder
completion flag. Over-limit audio is rejected rather than silently shortened.
