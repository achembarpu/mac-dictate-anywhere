# S1-mini MLX evaluation

Native Swift MLX is a promising Apple Silicon S1 backend. Keep production on the
verified llama.cpp context-reuse path while a separate backend change addresses
installation, cancellation, chunking, preparation and supported Macs. The new
[runnable Swift probe](../tools/s1-mlx-probe/README.md) supplies a concrete starting
point; MLX has not been added to the application target.

## Model and runtime

Use the [author's S1-mini weights and trained recipe](https://huggingface.co/superwhisper/s1-mini)
at revision `88f6b15896c73bbb13a3b596e0afe8ea0d5150b4`, converted locally with
official MLX tooling. Four-bit and eight-bit affine weights use groups of 64;
the original BF16 snapshot is also measured. The converted weight files occupy
about 320/604 MiB, excluding tokenizer/license files. Four-bit affine MLX and
the app's mixed Q4_K_M GGUF are different quantization formats, so this is not
an identical-weight comparison between runtimes.

The native package pins `mlx-swift-lm` 3.31.3, MLX Swift 0.31.6 and
`swift-transformers` 1.3.0, with all transitive revisions in `Package.resolved`.
The Python probe uses MLX 0.32.3, mlx-lm 0.32.0 and Transformers 5.18.0.
Both use the actual production prompt, non-thinking prefix, greedy generation,
input-sized output limit and 512-token prefill. All native prompt-token hashes
were checked against the author's Hugging Face tokenizer and non-thinking chat
template. There is no transcript-prefix reuse across requests.

[MLX executes on CPU/GPU with unified memory](https://github.com/ml-explore/mlx).
It does not add a Neural Engine path to S1. Current llama.cpp already uses Metal
on Apple Silicon. This experiment evaluates a different runtime and weight
format, rather than enabling a previously unused GPU.

## Measured outcomes

M3 Max, 36 GiB, macOS 26.7.1. Native Swift is Release optimized. Each MLX variant
has three trials of all seven authored English cleanup goldens after synthetic
preparation. Inference runs are serial. The current llama.cpp column is the
five-trial paired context-reuse benchmark on the same host and fixtures.

| Fixture | llama.cpp reused | Swift MLX 4-bit | Swift MLX 8-bit | Swift MLX BF16 |
| --- | ---: | ---: | ---: | ---: |
| Numbers/negation | 171.2 ms | 117.0 ms | 158.1 ms | 219.4 ms |
| Question | 51.7 ms | 44.0 ms | 51.8 ms | 67.8 ms |
| Correction | 61.0 ms | 48.2 ms | 60.3 ms | 78.6 ms |
| Already clean | 61.1 ms | 50.4 ms | 58.8 ms | 82.4 ms |
| Dictated instruction | 74.7 ms | 56.1 ms | 70.1 ms | 97.3 ms |
| Literal apology | 97.9 ms | 65.2 ms | 87.3 ms | 126.7 ms |
| Long complete ending | 3.75 s | 2.67 s | 3.45 s | 4.94 s |

These are medians. Native 4-bit was about 15–33% faster on these short cases.
Earlier long llama.cpp runs were noisy (3.68–7.45 s across fresh/reuse modes), so
do not claim an established long-text speedup. Runs are grouped, not interleaved across
runtimes. The native probe omits the app's normalization/fallback gates, and
quantization differs. Broader paired app-level checks must precede a switch.

All **147 measured MLX outputs** (84 native, 63 Python) reached EOS and had zero
checked fact/meaning misses in the existing Swift golden scorer. Short outputs
preserve the same checked facts; native 4-bit omits a comma in the apology case
that llama.cpp includes. Long outputs also vary in harmless formatting;
reference WER is approximately 0.29% for native 4-bit, 0.44% for native 8-bit/BF16
and 0.73% for llama.cpp. This small authored inventory does not establish general
accuracy superiority, and fact checks do not cover all possible meaning changes.

Keep MLX's normal unquantized cache: quantizing KV to 8 bits with 4-bit weights
made the native short medians 193–684 ms and the long median 17.18 s, roughly
4–6 times slower than its normal cache. Every checked output still completed.
The app's beneficial llama.cpp Q8 cache policy does not transfer automatically
to MLX. Higher-precision weights also failed to improve these checked facts.

The Python 4-bit/8-bit/BF16 generation loops were slower, with long medians
around 9.3–9.9 s. Their measurements cannot predict the native Swift backend.
Retain `scripts/evaluate_s1_mlx.py` for conversion/template/reference experiments,
and use the Swift executable for native runtime measurements.

## Preparation and remaining acceptance

Native 4-bit loading took 494 ms; its first synthetic decode took 1.03 s and
the repeated synthetic decode 28.8 ms. First measured numbers input took 193 ms
before subsequent 114/117 ms trials; the first long input took 3.13 s. Preparation
must cover actual inference, and a tiny synthetic input does not prove every
subsequent shape is fully warm. Shader caches were shared across serial variant
runs, so these are not controlled fresh-install/cold-machine comparisons.

Before adopting a backend, integrate the existing lossless chunker, complete
response/fallback rules, cancellation/error reset and model/context teardown.
Use normal persistent app caches with weight integrity checks and prepared
selected-model inference. Validate lower-memory Macs, minimum supported macOS,
native memory/energy, and app Stop latency. Keep the existing CPU path for Intel.
No user-facing processor knobs or automatic runtime switching are proposed.

[Raw outputs, timings, model/runtime/source hashes and shared quality scores](benchmarks/s1-mlx-evaluation-2026-10-02.json)
are committed alongside the probe and lockfile. Reproduction commands are in
its README; saved results use `--only cleanup-prompts`, the same scorer as
other candidate cleanup evaluations.
