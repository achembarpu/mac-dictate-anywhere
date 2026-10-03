# Native S1 runtime

S1-mini is an English cleanup model. Both backends retain the author's trained
control line, chat template, empty thinking block, greedy generation and input
limits. An arm64 process prefers the verified MLX 4-bit/group64 package;
x86_64 uses Q4_K_M GGUF with llama.cpp CPU inference. Existing GGUF remains usable
on Apple Silicon through Metal. See the [model runtime policy](model-aware-transcription.md)
for speech preparation and shared cleanup contracts.

## Request isolation and cancellation

The MLX actor serializes loading, prewarm, generation, chunk tokenization and
unload across suspension points. It caches only the fixed public system prompt.
Each request copies that cache and evaluates its own controls and transcript;
token-ID prefix equality protects tokenizer boundaries. No transcript history is
retained. GGUF reuses context allocations, clearing KV data/token positions after
success and discarding the context after cancellation or a decode error.

Both runtimes require EOS, including an EOS probe at the output budget. Incomplete
responses preserve the complete input through the shared service. Cancellation
is checked during generation, and outstanding GPU work is joined before return
or unload. Prewarm uses synthetic short/batched prefill and generation outside
user requests; it never contributes text to dictation.

Shared safety gates preserve the original when an explicit numeric minus sign
is lost or literal chat markers could be interpreted as controls. Chunking uses
the selected runtime's tokenizer and preserves every source character. These
checks do not guarantee arbitrary fact or meaning preservation.

## Model installation

The normal app model cache holds a complete `mlx/` or `llama/` package. New
installs download the recommended architecture format. Existing root GGUF files
remain usable offline; **Optimize Model** installs MLX alongside them on Apple
Silicon. Deletion removes both managed formats.

Packages pin weight, configuration, tokenizer, LICENSE and NOTICE assets by
revision, byte count and SHA256. Progress covers all assets. Only a fully verified
staged directory is installed. Failed/cancelled transfers remove staging and
retain the previous installation; concurrent downloads are rejected. Integrity
hashing runs off the main actor, joins concurrent checks and caches against all
package files' metadata. Changing runtime changes preparation identity, so the
new graph must be warmed before Settings can show it as ready.

## Runtime settings and diagnostics

Native MLX uses original BF16 floating tensors, normal KV, 256-token prefill steps
and a bounded 64 MiB temporary allocator cache. GGUF uses a 4,096-token context,
FP16 KV on Metal and Q8 KV on CPU. CPU threads use physical cores bounded by active
processors and capped at eight. Process architecture determines these paths;
Rosetta timing does not establish native Intel performance.

The app pins MLX Swift 0.31.4, MLX Swift LM 3.31.3 and Swift Transformers 1.3.0.
Keep committed dependency resolution and normal package-plugin validation.
Building shaders requires Xcode's Metal compiler component. The deployment target
is macOS 14; a supported build target alone does not establish throughput on
every Mac or OS version.

`cleanup.prefillSchedule` measures CPU scheduling; `cleanup.firstToken` ends when
prompt work yields a token visible to the sampling loop. Request/generation spans
include the complete response and cleanup. See the [tracing map](performance-tracing.md),
[benchmark commands](performance-benchmarking.md) and
[standalone probe](../tools/s1-mlx-probe/README.md) for diagnostics.

Model sources: [author recipe](https://huggingface.co/superwhisper/s1-mini),
[MLX conversion](https://huggingface.co/mlx-community/S1-mini-MLX-4bit),
[official runtime](https://github.com/ml-explore/mlx-swift-lm).
