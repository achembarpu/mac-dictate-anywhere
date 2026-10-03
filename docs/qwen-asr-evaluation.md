# Qwen3-ASR precision and multilingual screen — 2026-10-03

Keep Qwen3-ASR out of the app from this screen. The 0.6B 4-bit model translates
and invents content in mixed Chinese/English speech. Moving to 8-bit repairs
that case, but still loses a quiet speaker's negation and costs substantially
more time than the existing native path. Retain the precision finding, local
models and reusable collector rather than expanding the matrix.

## Configuration and scope

The [author's model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) documents
30 languages and 22 Chinese dialects, automatic or forced language, and a
256-token example budget for short input. Its CUDA/vLLM concurrency figures
do not establish Mac interactive latency. Use automatic language, greedy
decoding, batch size one and 256 tokens; no hotwords or reference-derived hints.
No timestamps/forced aligner, custom prompt or unverified long-audio seams.

Screen the community [4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit)
and [8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) conversions,
group size 64, affine quantization. Exact revisions and all ten assets per
checkpoint are verified against public Git blob IDs and LFS SHA256. Weights:
708,236,945 / 1,006,229,426 bytes. Checkpoint metadata is committed beside the
results. The tokenizer has no custom-code mapping or Python assets; the strict
local loader runs offline. No implicit inference-time download.

Isolated Python 3.12, mlx-audio 0.5.7, MLX/Metal 0.32.3, NumPy 2.5.3,
SoundFile 0.14.0, Transformers 5.18.0 and huggingface-hub 1.33.0. Public
`generate` API; SDK prefill 2048 and chunk duration 1200 seconds. All selected
files are under 30 seconds, so each is one complete chunk. The S1 MLX child's
production MLX 0.31.4 / LM 3.31.3 pins are unchanged.

One M3 Max, 36 GiB, macOS 26.7.1. Five selected 4-bit cases, three measured
trials each over two serial runs. Only the two substantive failures advance to
one 8-bit contrast trial each. One shape warmup per fixture/run outside timing;
warm timers include WAV reading, PCM conversion, SDK preprocessing, generation
and final GPU synchronization. No overlapping compilation. Native SenseVoice
uses three exact fixtures, three trials each through the app recording-file
path in the signed optimized Release test host.

## Accuracy and time

Shared Swift WER/CER, unchanged human references. All 4-bit texts repeat
exactly across three trials. Native Dutch/German v3 comparisons are historical:
audio/reference bytes, model weights and production source hashes match.

| Case | Metric | Existing native error / median ms | Qwen 4-bit error / median ms | Qwen 8-bit error / ms |
| --- | --- | ---: | ---: | ---: |
| Mandarin reading | CER | SenseVoice 0% / 38.4 | 0% / 112.7 | Not run |
| Dutch reading | WER | v3 6.67% / 52.8 | 20% / 140.2 | Not run |
| German reading | WER | v3 11.11% / 104.9 | 11.11% / 176.9 | Not run |
| Chinese/English switch | CER | SenseVoice 4.8% / 96.8 | 51.2% / 258.3 | 3.2% / 327.1 |
| Quiet spontaneous AMI | WER | SenseVoice 22.58% / 32.6 | 29.03% / 160.2 | 16.13% / 202.4 |

The switch is a constructed different-speaker composite with 200 ms seams,
not natural code-switching. AMI is quiet headset meeting audio. Neither tests
live microphone/VAD/Stop behavior. Raw scores also penalize names and numeral
spelling; a lower score does not establish preservation of meaning.

4-bit changes the English “apostle of the middle classes” into Chinese claims
about a gospel and a New England pastor. 8-bit retains the original English
sentence. Precision therefore matters here; do not reject every Qwen variant
based only on the 4-bit failure. Both quants still omit “didn't get anything
else” and change the final question in the AMI clip. Existing v3/Ultra/Phonon
also miss its negative clause; historical v3 WER is 22.58% on identical bytes.

8-bit improves the two selected error scores but takes 26.6–26.7% more time
than 4-bit and 3.4–6.2 times the native SenseVoice file time. These are Python
versus native API observations, not predictions of native Swift Qwen speed or
causal quantization-only comparisons. One 8-bit trial is a diagnostic, not a
latency distribution. Its small switch-score improvement does not justify
another product runtime. Prune 1.7B, BF16, 6-bit, aligner and prompt sweeps;
revisit for a demonstrated language/quality gap with broader native gates.

All 17 saved outputs finish below 256 tokens (17–60 tokens). The reviewed
single-chunk generator can stop on EOS or the budget, consuming EOS before
returning public output. Below-budget termination is therefore inferred EOS;
the SDK does not expose a finish reason. Retain this limitation and every raw
token count/budget flag rather than claiming directly reported EOS.

## Resources and integration boundary

Installed assets: 679.8 MiB 4-bit / 963.9 MiB 8-bit, storage rather than RAM.
MLX allocator peak: 1.508–1.850 GB 4-bit / 1.876–2.148 GB 8-bit. Lifetime
process RSS: up to 1.185 / 1.469 GB, including Python, integrity reads and
preceding calls. These counters describe different allocations and must not be
added or treated as total model/system RAM. No energy or Intel/base-M/8GiB
performance claim. Local load is 1.56–2.87 seconds, excluding integrity checks
and first-file warmup; it is not usage latency after a native prewarm.

Assets are in persistent app `Models/Qwen3-ASR-0.6B-{4,8}bit` directories for
future native reuse; the app cannot select Qwen today. The native
[mlx-audio-swift model implementation](https://github.com/Blaizzy/mlx-audio-swift/tree/main/Sources/MLXAudioSTT/Models/Qwen3ASR)
admits current S1 dependency versions by its declared ranges, but build,
lifecycle, minimum OS, universal packaging and Intel fallback are unverified.
Token streaming over supplied complete audio is not incremental live ASR.
Native integration also needs the base Apache license/NOTICE packaged; the
conversion repository does not include those assets. No app dependency added.

## Reuse and checks

`scripts/evaluate_qwen_asr.py` uses the same licensed golden inventory and
saved-output scorer as other candidates. Supply a local checkpoint and its
matching committed metadata; the collector performs no downloads:

```sh
python scripts/evaluate_qwen_asr.py --model-path "$QWEN_MODEL_DIR" \
  --model-metadata docs/benchmarks/qwen-asr-4bit-metadata.json \
  --output /tmp/qwen-asr.json --fixture golden-zh-1 \
  --fixture golden-nl-1 --fixture golden-de-1 \
  --fixture golden-zh-en-switch --fixture golden-en-ami-2
PIPELINE_BENCHMARK_ASR_RESULTS_PATH=/tmp/qwen-asr.json \
  scripts/dev.sh benchmark --release --only external-asr-quality
PIPELINE_BENCHMARK_MODEL=senseVoice \
  PIPELINE_BENCHMARK_FIXTURE=golden-zh-1,golden-zh-en-switch,golden-en-ami-2 \
  scripts/dev.sh benchmark --release --only asr-file
```

For the precision contrast, select the 8-bit directory/metadata and only the
two failed fixtures with `--iterations 1`. Use an isolated research environment
with the versions above. For downloads, use `snapshot_download` with the exact
revision in the metadata and the persistent app Models directory as `local_dir`.
The 8-bit contrast does not authorize a new production dependency upgrade.

[The artifact](benchmarks/qwen-asr-screen-2026-10-03.json) retains 17 external
and nine native outputs, all shared scores, exact original collection scripts,
runtime/model/source/input/log hashes and six reverified native weight files.
The combined Release check passes two tests with one unconfigured local-endpoint
test skipped. Ruff and the existing two Python SDK-error/release tests pass;
a tampered pinned config fails before model import, inference or output.
`asr-file` now accepts exact comma-separated fixture IDs and rejects duplicates
or unknown IDs, allowing bounded comparisons without another full matrix.

Fresh normal Team-signed Debug builds and suites pass at `af5183f` (parent):
639 total / 564 passed / 75 skipped / zero failures; `ca30de5` (MLX child):
656 / 574 / 82 / zero. Both fresh detached checkouts were removed. Later
research-script import/executable fixes leave generation logic unchanged;
full-repository Ruff and both pytest cases pass on both branches. Historical
source hashes retain their original collection provenance. Final verification
and formatting hashes are in the [readiness artifact](benchmarks/model-stack-readiness-2026-10-03.json).
