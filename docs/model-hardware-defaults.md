# Model hardware defaults

The app chooses each model's supported settings internally. There is no hardware
picker, calibration workflow, or tuning at startup. Prefer the model author's
and runtime's documented configuration; validate optional recommendations before
changing a production default. Keep model selection and useful cleanup styling
separate from processor placement.

## Current execution paths

| Model or component | Native Apple Silicon | Intel / x86_64 process |
| --- | --- | --- |
| Parakeet v2, v3, Ultra, 110M | Core ML CPU/Neural Engine defaults; CPU preprocessing | SDK configuration permits CPU fallback |
| Parakeet EOU / English Nemotron | Core ML CPU/Neural Engine defaults | SDK configuration permits CPU fallback |
| Multilingual Nemotron | Core ML int8, CPU/Neural Engine | Unavailable: SDK requires an arm64 process |
| SenseVoice | Core ML int8 encoder, CPU/Neural Engine; CPU preprocessing | FP32 encoder, Core ML `.all`; CPU preprocessing |
| Silero VAD | CPU/Neural Engine | CPU |
| CTC vocabulary matching | Core ML CPU/Neural Engine default | SDK configuration permits CPU fallback |
| S1-mini cleanup | llama.cpp Q4_K_M with Metal GPU offload | llama.cpp Q4_K_M on CPU |

These describe allowed execution paths, not a guarantee that every operation
runs on the named accelerator. Apple's
[`MLComputeUnits`](https://developer.apple.com/documentation/coreml/mlcomputeunits)
controls which processors Core ML may use. SenseVoice's FP32 `.all` fallback
allows the OS to choose available processors (CPU/GPU on Intel); it is not
explicitly CPU-only. Apple Speech,
Apple Intelligence and remote services control their own execution placement.

The existing architecture gate deliberately describes the process. A Rosetta
x86_64 process cannot load FluidAudio's arm64-only multilingual Nemotron even
when the physical machine has a Neural Engine. Keep model availability aligned
with the SDK rather than offering a download that cannot run.

## Why these defaults

- [FluidAudio's v3 encoder guidance](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/EncoderComputePlacement.md)
  retains CPU/Neural Engine as the default and reports an optional GPU encoder
  gain on its benchmark. It keeps CPU preprocessing and default decoder/joint
  placement: routing the whole pipeline to GPU adds overhead. Our paired
  golden benchmarks determine whether that optional change helps locally.
- [SenseVoice's conversion guidance](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/SenseVoice.md)
  identifies incorrect FP16 CPU/GPU output. The
  [pinned loader](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Sources/FluidAudio/ASR/SenseVoice/SenseVoiceModels.swift)
  uses CPU/Neural Engine for FP16/int8 and `.all` for FP32. The app selects int8
  on arm64 and the larger FP32 build otherwise; do not force the compact
  encoder onto a processor where it is incorrect.
- [Multilingual Nemotron guidance](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/NemotronMultilingual.md)
  targets its int8 encoder to the Neural Engine and reports a large GPU
  slowdown with `.all`. Preserve the documented configuration.
- [S1-mini's model card](https://huggingface.co/superwhisper/s1-mini) supplies
  the prompt, thinking-disabled prefix, greedy decoding, input-sized output
  budget and approximately 1,000-token input chunks. The author's
  [GGUF card](https://huggingface.co/superwhisper/s1-mini-GGUF) recommends Q4_K_M.
  The app retains these policies plus its verified 4,096-token context and Q8
  KV cache. [llama.cpp's Metal backend](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md#metal-build)
  supplies GPU execution on Apple Silicon; the existing Intel CPU path remains
  until actual Intel model tests justify a change. The cards do not prescribe
  a universally optimal per-chip thread count, so keep the existing bounded
  thread policy instead of guessing one from chip names.

Core ML and MLX are frameworks, while CPU/GPU/Neural Engine are processors.
[MLX](https://github.com/ml-explore/mlx) supports CPU/GPU execution and unified
memory on Apple Silicon. Production S1 continues to use llama.cpp. A standalone
[native S1 MLX evaluation](s1-mlx-evaluation.md) shows promising 4-bit latency
on M3 Max with preserved checked facts. Adoption still requires application
lifecycle, installation and additional-device verification; a hardware toggle
would not perform that integration. MLX's quantized KV cache was substantially
slower in this workload, so retain its normal cache for further evaluation.

## Preparation and different Macs

Prepare the selected speech/VAD graphs and eligible cleanup before Ready using
the same execution path as real dictation. Synthetic inference is discarded;
native streaming state resets before real speech. Repeated preparation reuses
loaded weights. Model/settings/download changes use the existing idle-time
preparation lifecycle. Prewarm only the selected models, not copies for every
processor, to keep preparation bounded on lower-memory Macs.

Do not infer performance from M-series generation or Pro/Max/Ultra branding
alone, change quantization or decoder context silently, or switch processors
during a recording. The current choices rely on supported process architecture
and model requirements. There is no claim that one placement is fastest on
every supported Mac. Actual Intel and additional Apple Silicon machines are
needed to establish broader performance results.

Keep hardware experiments in the existing developer benchmark harness:
[benchmark setup](performance-benchmarking.md). They do not run in the product's
startup or dictation flow. Measured hardware evidence is recorded with the
[model results](model-aware-transcription-results.md).

## Optimized placement verification

The follow-up on 2026-10-02 uses both the app and XCTest harness compiled with
`-O`, local Team signing, FluidAudio 0.17.5, and the same installed weights.
M3 Max / 36 GiB / Mac15,10, macOS 26.7.1 (25G241): all 11 supported goldens for
each of v3 and Ultra run five paired repetitions, alternating execution order.
All 110 paired comparisons retain equal fixture WER (220 individual decodes).

Warm fixture medians favor Neural Engine on every tested case. GPU takes
**1.34×** v3's and **4.71×** Ultra's workload time, calculated as the ratio of
summed fixture medians after excluding each fixture/placement's first trial.
Retain the SDK default; the optional upstream GPU result is not reproduced on
this Mac. The original unoptimized-harness report remains historical evidence.

The [hardware report](benchmarks/model-hardware-defaults-2026-10-02.json) retains
all trials, methods, runtime-source hashes and eight reverified weight hashes.
These small fixture probes do not establish population WER, power efficiency,
or the fastest placement on other Macs. Reproduce using the existing setup:

```sh
DERIVED_DATA_PATH="$PWD/DerivedData" \
PIPELINE_BENCHMARK_MODEL=multilingual \
PIPELINE_BENCHMARK_ENCODER=1 \
PIPELINE_BENCHMARK_ITERATIONS=5 \
scripts/dev.sh benchmark --release --only asr-quality
```

Repeat with `PIPELINE_BENCHMARK_MODEL=multilingualUltra`. Neither command adds
settings, downloads models implicitly, or runs at normal app startup.
