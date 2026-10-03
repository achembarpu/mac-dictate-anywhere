# Moonshine Small Streaming CPU screen — 2026-10-03

Do not add Moonshine to the app in this PR. One current Small Streaming tier
has enough accuracy/session-isolation failures to stop expansion to Medium or
Tiny. Retain its local model, collector and failed outputs for future work.
This screen changes no product dependency, picker, runtime or default.

## Configuration and scope

Moonshine Voice 0.1.5, shipped ONNX Runtime 1.23.2, Small Streaming 123M English,
official `quantized_26_08_21` per-channel int8 assets. CPU provider; default
speculative decoding, 6.5 tokens/second guard and 0.5-second update floor.
Disable returned PCM, timestamps and diarization; no keyterms/context derived
from references. Native ORT threading remains the shipped default. The
`MOONSHINE_ORT_SINGLE_THREAD=1` override is a separate rejected diagnostic.

Primary [model documentation](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/),
[quantization guidance](https://moonshine-voice.readthedocs.io/en/latest/models/quantization/)
and [options](https://moonshine-voice.readthedocs.io/en/latest/api/options/).
Use the current Moonshine repo, not old moonshine-v2 placeholder tables.
The upstream [provider guide](https://github.com/moonshine-ai/moonshine/blob/234f60faa0eb388b01cdf7e60aca232af37aefda/docs/execution-providers.md)
recommends CPU; fused ORT operations limit useful Core ML offload. Prune that
provider path and obsolete non-streaming checkpoints before benchmarking.

Four selected English goldens: long reading/names, FLEURS numbers/negation,
quiet spontaneous AMI male speech, AMI names/self-correction. Three trials per
case and configuration, one shape warmup outside the timer, 36 saved outputs.
Fresh stream per trial; feed 100 ms chunks without sleeps, then flush at Stop.
These measure compute, not real microphone scheduling. They are a small gate,
not population WER or an Intel/low-memory-Mac benchmark.

## Accuracy and reliability

All outputs use the existing signed Release Swift WER scorer and unchanged
human references. Historical v3 rows have identical audio/reference bytes.
The early readings used the 20-pair manifest; AMI and this collector use the
23-pair manifest. Per-fixture hashes establish that comparison, not matching
whole-inventory hashes.

| Fixture | v3 raw WER | Moonshine streaming | Moonshine whole utterance, VAD off |
| --- | ---: | ---: | ---: |
| Reading/names (`golden-en-5`) | 5.63% | 9.86% | 12.68% |
| FLEURS numbers (`golden-en-fleurs-1`) | 11.76% | **100% once**, 17.65% twice | 17.65% |
| AMI quiet male (`golden-en-ami-2`) | 22.58% | 51.61% | 67.74% |
| AMI names (`golden-en-ami-3`) | 0% | 15.62% | 6.25% |

The single-thread run repeats the same streaming texts and empty-output failure.
The shared scorer deliberately fails its nonempty-speech assertion for both
empty outputs; retain them as 100% WER, never omit them or report the screen as
passing. Other repeated outputs are stable. Number spelling contributes to raw
FLEURS WER; the important semantic failures are in spontaneous speech. Streaming
changes “about what the project is” to “Got one of the projects” and loses
“didn't get anything else.” The VAD-off whole-utterance path also loses the final
question. Neither path repairs the quiet-speech omission seen in native models.

The [author's accuracy recipe](https://moonshine-voice.readthedocs.io/en/latest/models/accuracy/)
disables VAD for presegmented utterances. We tested that path as a diagnostic,
rather than treating default VAD errors as model-only errors. Current inspected
source shares a global stateful Silero VAD across streams; its recurrent state
and audio context are not reset by stream start. This plausibly contributes to
the repeated quiet-clip inconsistency. It is not an isolated causal experiment,
and the wheel does not expose its source revision. Integration would need an
upstream fix or independently isolated VAD, with native packaging/completion
gates. A larger model does not address that runtime contract by itself.

## Performance and resources

Default streaming p50 compute: 3,884.2 / 619.6 / 767.3 / 1,085.4 ms for the four
fixtures above. The 29.4-second reading uses 30,774.4 ms of process CPU time;
its p50 final flush is 72.5 ms. First visible text appears after 1.1 seconds of
fed audio (0.5–1.6 seconds across the panel), not that many wall-clock seconds.
Final-flush time excludes work already done while feeding audio.

Single-thread reading compute is 11,110.5 ms, 2.86× slower, with 11,110.3 ms CPU
time. Other fixtures are 2.70–2.91× slower. Lower CPU time is a tradeoff, not an
energy measurement or the best interactive latency setting. Reject the override.
VAD-off whole-utterance timings overlapped Xcode compilation and are retained
only as diagnostics; do not use them to rank performance. Native v3's historical
single-final-file workload differs from repeated streaming preview work.

Verified assets total 142,300,974 bytes (135.7 MiB). Cold local load is about
69–72 ms, excluding download/integrity checking and first-file warmup. Lifetime
process peak RSS reaches 1,664,712,704 bytes by the default panel's end and
1,559,969,792 with one thread. This includes Python, checksum reads, native
allocations and prior calls; it is not model-only RAM or accelerator memory.
No energy, whole-system memory, native Intel throughput or live Stop claim.

The installed wheel's dylibs are arm64-only. The inspected Swift package points
at a local XCFramework absent from the clone. A native app integration would
need verified arm64/x86_64 distribution and license packaging. The downloaded
`.ort` assets are in the persistent app Models directory for future native use;
the app cannot select Moonshine today.

## Reuse and verification

Collector: `scripts/evaluate_moonshine.py`. Exact model catalog and every saved
output/resource counter, scorer result, runtime/model/source hash and original
collection script are in
[the artifact](benchmarks/moonshine-screen-2026-10-03.json). Final source differs
from collection only by import sorting and executable file mode.

Install an isolated research environment with `moonshine-voice==0.1.5`,
`numpy==2.3.3`, `soundfile==0.13.1` and `google-crc32c==1.9.0`. Download only
the selected official Small model through `download_model_from_info`, passing
the app Models directory as `cache_root`; the collector performs no downloads.
Supply its resulting local model directory:

```sh
python scripts/evaluate_moonshine.py --model-path "$MOONSHINE_MODEL_DIR" \
  --model-catalog docs/benchmarks/moonshine-small-catalog-2026-10-03.json \
  --output /tmp/moonshine.json --fixture golden-en-5 \
  --fixture golden-en-fleurs-1 --fixture golden-en-ami-2 --fixture golden-en-ami-3
PIPELINE_BENCHMARK_ASR_RESULTS_PATH=/tmp/moonshine.json \
  scripts/dev.sh benchmark --release --only external-asr-quality
```

Add `--mode whole-utterance --disable-vad` for the author's accuracy diagnostic.
Run `MOONSHINE_ORT_SINGLE_THREAD=1` separately only to reproduce its rejected
tradeoff. Do not run inference during compilation for comparative timing.
Stream errors or a swallowed `None` final result abort collection; segmentation
`is_complete` does not imply decoder EOS or absence of token-rate truncation.
Two focused pytest cases verify error rejection and stream release. Ruff passes.
Fresh normal Team-signed Debug builds and tests pass from detached checkouts:
parent `ea0472d`: 639 total / 564 passed / 75 skipped / zero failures; MLX child
`8e097d0`: 656 / 574 / 82 / zero. A tampered catalog is rejected before inference
or output. Signing files stay ignored; temporary validation checkouts removed.
Build/test log hashes are retained in the artifact. Reproduce the two error
checks with `uv run --with pytest python -m pytest scripts/tests/test_moonshine_collector.py -q`.
