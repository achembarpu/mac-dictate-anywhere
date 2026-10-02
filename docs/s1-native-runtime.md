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
