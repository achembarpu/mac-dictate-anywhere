# Native S1 runtime

S1-mini keeps the author's trained control line, chat template, empty thinking
block, greedy generation and input/output limits on both backends. Apple Silicon
can load the verified native MLX 4-bit/group64 package; Intel uses the existing
Q4_K_M GGUF with llama.cpp CPU inference. Model installation selects the runtime.

The MLX actor owns its model/tokenizer and serializes loading, prewarm, generation,
chunk tokenization and unload across suspension points. Only the fixed **public
system prompt** is cached. Each request copies that cache and evaluates its own
controls and transcript; token-ID prefix equality protects tokenizer boundaries.
No transcript history is retained. Completion requires EOS, and unfinished
responses preserve the entire input. Cancellation checks every output token and
joins GPU work before returning or unloading. Prewarm exercises short and batched
prefill plus autoregressive kernels with synthetic input, outside usage time.

Measured tuning uses normal KV, prefill steps of 256 and a bounded 64 MiB temporary
allocator cache. 128/256/512/1024 prefill and cached/uncached comparisons are retained
in the standalone probe. The registered `s1-runtime` benchmark uses the actual app
service, normalization and safety gates, alternating backend order. It includes
21 authored English references (14 new stress cases), five trials and all outputs.

The stronger references exposed loss of a numeric minus sign in both 4-bit and
8-bit S1. Shared safeguards retain the original when an explicit numeric minus
sign disappears, or literal chat markers could be interpreted as prompt controls.
They do not prove arbitrary cleanup preserves every fact.

Dependencies: official MLX Swift LM 3.31.3, MLX Swift 0.31.4 and Swift Transformers
1.3.0, with committed resolution locks. MLX Swift 0.31.4 is the compatible macOS
release used here; 0.31.5/0.31.6 add a CUDA build plugin requiring Xcode trust. Normal
package-plugin validation remains enabled. Native performance parity was checked.
Xcode's Metal compiler component is needed to build shaders. macOS 14 is the
minimum target. Real execution measurements currently come from one Apple Silicon
Mac; Intel cross-build/runtime evidence and detailed measurements are recorded in
the integration report.

Sources: [S1 author recipe](https://huggingface.co/superwhisper/s1-mini),
[verified MLX conversion](https://huggingface.co/mlx-community/S1-mini-MLX-4bit),
[official runtime](https://github.com/ml-explore/mlx-swift-lm).

## Model installation

The normal model cache holds a complete `mlx/` or `llama/` package. Apple Silicon
prefers MLX; Intel selects GGUF and never initializes the MLX graph. Existing root
GGUF downloads remain usable offline. Apple Silicon offers **Optimize Model** to
install the smaller MLX package alongside them; new installs download the
recommended format directly. Deleting the model removes both managed formats.

Every new package includes pinned weight/config/tokenizer hashes plus the author's
full LICENSE and NOTICE. Download progress covers all assets. Failed or cancelled
transfers remove staging data and retain the previous installation; concurrent
operations are rejected. Integrity hashing runs off the main actor, is coalesced
and cached against every package file's metadata. A complete directory is committed
only after verification. Changing runtime changes the preparation identity, so the
new graph is warmed before it can be shown as prepared.

## Runtime tuning and inspection

Native MLX keeps normal KV. The Metal GGUF path uses FP16 KV after a paired
accuracy/performance check; Intel CPU keeps Q8 KV, which performed better in the
available x86/Rosetta run. CPU threads use physical cores, bounded by active
processors and capped at eight, to avoid oversubscribing Intel's SMT siblings.
Rosetta validates the Intel code path; its timings do not predict native Intel
hardware.

`cleanup.prefillSchedule` measures CPU scheduling. `cleanup.firstToken` ends when
GPU/CPU prompt work has produced a token visible to the sampling loop. These
spans avoid mistaking asynchronous scheduling time for completed inference.
Request/generation spans still include the complete response and graph cleanup.
