# Quiet input: amplitude and quantization — 2026-10-03

The quiet golden exposes Float32 amplitude sensitivity, with additional PCM16
quantization loss. Keep product audio unchanged while testing a modest boost
in live/VAD and real noise cases. This screen does not establish a safe default.

The independently referenced FLEURS clip is already quiet: RMS 0.0007306,
peak 0.007294. Multiplying it by 0.1 in Float32 preserves its relative detail.
The PCM16 quiet derivative adds quantization: RMS 0.00007538 is only about 2.47
integer steps. Comparing only that file would conflate the two effects.

## Results

Production ASR config and installed models; raw Float32 samples with a fresh
decoder state per call. Three trials, one shape warmup per variant outside the
timer, M3 Max/36 GiB/macOS 26.7.1. All 105 outputs are deterministic across trials.

| First clip / variant | v3 WER | 110M WER |
| --- | ---: | ---: |
| Original source | 11.76% | 0% |
| Quiet Float32, 0.1× source | 58.82% | 100% |
| Quiet PCM16 derivative | 70.59% | 100% |
| Either quiet input, then 4× gain | 11.76% | 0% |
| Either quiet input, then 16× or 64× gain | 11.76% | 0% |

On the second speaker/name clip, v3 is 21.43% WER for the source and quiet
Float32 baseline; 4× gain improves to 14.29%, while 16×/64× return to 21.43%.
This supports investigating modest gain, not assuming more gain is better.
Remaining name errors need a different mechanism. The first clip's normal v3
error is number formatting, distinct from the quiet variant's corrupted words.

Both models return empty text for one-second silence, seeded uniform noise
and its 16× amplified copy. These are synthetic controls, not a real noise
safety test. Live VAD, preview/Stop and natural background noise remain pending.
No product gain, recording change or user control is added by this increment.

Quiet-restored p50 is about 57–59 ms for v3 and 25–27 ms for 110M. Transforms/
hashes are outside the timer, and the reference variant is early in grouped
runs. These timings do not prove a speedup. The wrong shortened 110M baseline
decodes faster because it returns only a few words; that is not a performance win.
The short-file SDK overload calls this same raw-sample path, without the app
volume gate. Feature flooring/dither/normalization or model amplitude response
are hypotheses; this screen does not isolate their causes.

## Reuse and limitations

The [artifact](benchmarks/tdt-acoustic-screen-2026-10-03.json) retains all outputs,
medians, input Float32 hashes/RMS/peaks, source/log/dependency hashes and process
CPU/RSS. WER uses the shared scorer. There are only two independent read-speech
clips; derived acoustic controls are correlated and are not pooled. CPU/RSS
exclude Core ML helpers/accelerators and are not energy or whole-model RAM.

```sh
PIPELINE_BENCHMARK_MODEL=multilingual PIPELINE_BENCHMARK_ITERATIONS=3 \
  DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only asr-acoustics
```

Select `compactEnglish`, `englishOnly` or `multilingualUltra` for another installed
TDT model, or `PIPELINE_BENCHMARK_FIXTURE=golden-en-fleurs-2` for another golden.
Each run loads one model. Gain labels are ceilings; peaks cap at 0.99 instead of
clipping. PCM16 comparisons appear when a `-quiet` derivative exists. Normal
tests skip inference. No models download automatically and no audio leaves the Mac.
