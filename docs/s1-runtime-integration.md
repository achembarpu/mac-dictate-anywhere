# S1 runtime integration

`feature/s1-mlx-integration` is stacked on `feature/model-aware-transcription`
at `d398ea7`. Native Swift MLX now runs S1 cleanup on Apple Silicon. Intel keeps
llama.cpp CPU inference. Installation, preparation, complete-response handling
and the existing lossless chunker are shared. No processor or decoder tuning
controls are added to the product.

The measured defaults use the author's dedicated cleanup model. A smaller
general-purpose replacement, higher precision, alternative quantization groups,
prefill sizes and allocator limits were evaluated before choosing them.

## Defaults and supported Macs

| Path | Model | Defaults |
| --- | --- | --- |
| Apple Silicon, new/optimized install | S1 native MLX affine 4-bit, group64 | Greedy author recipe, normal unquantized KV, prefill 256, copied public prefix, 64 MiB temporary allocator cache |
| Intel | S1 Q4_K_M GGUF, llama.cpp CPU | Greedy author recipe, Q8 KV, physical CPU cores capped at eight |
| Apple Silicon, retained GGUF install | S1 Q4_K_M GGUF, llama.cpp Metal | Greedy author recipe, FP16 KV; Optimize Model installs MLX alongside existing files |

The official native dependencies are pinned to MLX Swift LM3.31.3, MLX Swift
0.31.4 and Swift Transformers 1.3.0. The complete resolutions are committed for
the app and standalone probe. The existing llama.swift 2.10549.0 remains pinned.
MLX Swift 0.31.4 builds with normal Xcode package-plugin validation; no validation
bypass is used. The later CUDA build plugin is unnecessary for this Mac backend.

MLX executes S1 on the GPU through Metal and unified memory. It does not introduce
a Neural Engine/Core ML path. Intel never initializes the MLX inference graph.
The deployment target remains macOS 14. CPU thread selection respects physical
cores and available processors to avoid Intel SMT oversubscription; the cap is a
conservative default for this small graph, not a measured optimum on every Intel
Mac. [Official MLX runtime](https://github.com/ml-explore/mlx),
[llama.cpp CPU tuning guidance](https://github.com/ggml-org/llama.cpp/blob/master/docs/development/token_generation_performance_tips.md).

## Paired app performance

Signed, optimized Release app and tests on M3 Max / 36 GiB / macOS 26.7.1,
Xcode 27.0 / Swift 6.4. Five trials of 21 authored English cases in four alternating
modes produced **420 outputs**. Weights and synthetic preparation are outside
request timers. Tokenization, generation, normalization, safety/fallback handling
and graph drain are inside. All inference runs are serial.

The baseline explicitly uses the parent's reused llama.cpp allocation and Q8 KV.
MLX and GGUF use different quantization formats, so runtime and model-format
effects cannot be separated by this comparison.

| Fixture | Reused GGUF Q8 p50 | MLX p50 | Lower latency |
| --- | ---: | ---: | ---: |
| Numbers / negation | 180.8 ms | 103.7 ms | 43% |
| Question | 54.2 ms | 37.3 ms | 31% |
| Spoken correction | 63.2 ms | 42.0 ms | 34% |
| Already clean | 63.4 ms | 42.0 ms | 34% |
| Dictated instruction | 77.1 ms | 49.9 ms | 35% |
| Literal apology | 99.7 ms | 59.3 ms | 41% |
| Long complete ending | 3,858.0 ms | 2,559.4 ms | 34% |

Context allocation reuse in the parent removed roughly 23–26 ms from short
requests. The larger remaining cost was prompt evaluation and autoregressive
decoding. Changing to the native runtime/weight format improves that work.

The public prefix is only **51 tokens**. Caching it saves around 5–6 ms on most
short fixtures in this run (18.9 ms on the numbers case), with no consistent long
benefit. Cached and uncached MLX outputs are exactly equal on every case/repeat.
Caching transcript history would violate request independence and is not used.
The legacy Metal path also improves: FP16 KV is about 8–10% faster than Q8 here.

## Preparation and first use

Preparation loads the graph/tokenizer, builds the fixed prefix, then exercises
short and batched prefill plus an autoregressive step using synthetic text.
The selected model is prepared through the existing app lifecycle. Changing
installed runtime changes the preparation identity and invalidates ready status.

Three unload/load trials measured preparation at 516–538 ms. On a separate short
invoice input, prepared first requests were 73.4–73.9 ms, matching subsequent
requests at 73.5–74.0 ms. Without preparation, the first graph request was 968 ms;
later graph reloads were 468–471 ms. These are graph-cold measurements: OS file
caches and compiled GPU pipelines were not flushed. The first-use delay is moved
to preparation rather than hidden in the request timer.

Only immutable public prompt tensors persist between requests. Each generation
copies them and evaluates fresh controls/transcript tokens. Token-ID prefix
equality protects tokenizer boundaries. The actor serializes asynchronous model
loading, prewarm, chunk tokenization, generation and unload. Cancellation is
checked per generated token; GPU work is joined before return/unload. EOS is
required, including an extra EOS probe at the output budget. An incomplete
response preserves the entire original input through the shared service.

## Quality and rejected alternatives

All 420 app outputs have zero checked meaning/fact misses. A final 84-output review
run also passes the explicit factual-loss regression assertions. Fourteen new
stress references cover decimals, negative amounts, identifiers, URLs, literal
instructions/chat tokens, corrections, negation, whitespace, names and questions.
They are committed with the shared scorer and benchmark groups.

Raw S1 output still loses an explicit numeric minus sign and interprets literal
chat markers in these cases. The service now preserves the original for either
condition. The negative-amount case runs decoding before the sign safeguard;
the literal-marker case returns before loading/decoding and its near-zero time
is excluded from the performance table. These safeguards also protect the GGUF
path. They do not detect every possible semantic error.

| Native alternative | Long p50 | MLX tracked peak | Decision |
| --- | ---: | ---: | --- |
| 4-bit/group64, cache 64 MiB | 2,523 ms | 714 MiB | Selected; two raw failure cases covered by shared safeguards |
| 4-bit/group32 | 2,636 ms | 749 MiB | Also drops the final “not Thursday” negation |
| 4-bit/group128 | 2,468 ms | 696 MiB | Slightly faster but also drops that negation |
| 8-bit/group64 | 3,279 ms | 999 MiB | Same two raw failure cases; no checked quality improvement |
| 4-bit/group64, floating tensors cast to FP16 | 2,522 ms | 714 MiB | Drops the final “not Thursday” negation; rejected |
| Qwen3.5-0.8B 4-bit | 2,675 ms | 756 MiB | Rejected: incomplete and unfaithful responses |

The quiet final quantization/cache matrix uses production MLX Swift 0.31.4.
The eight-bit and earlier prefill matrix use 0.31.6; their exact versions are
recorded. Across the BF16 group/cache matrix, all 378 raw outputs reach EOS: 42 miss checks
before safeguards, including six additional group32/128 negation losses.
The earlier 147-output precision/prefill set has four raw misses, all in the
extended eight-bit sign/literal-marker cases.

The extra FP16 cast reaches EOS on all 63 outputs but has nine raw misses:
the existing sign/marker failures plus three lost-negation outputs. Most short
medians improve only 2–3%, and long latency stays unchanged. Production therefore
keeps the package's original BF16 floating tensors. This cast changes the native
model arithmetic; it is separate from llama.cpp's beneficial FP16 KV cache.

Qwen uses its own non-thinking chat template and current author text-task recipe:
temperature 1, top-p 1, top-k 20, presence penalty 2, with three fixed seeds.
54/63 outputs miss content checks, 22 are unfinished, and 56 violate either gate.
Every fixture has at least one rejected seed. The saved-output protocol test
fails its 22 completion assertions as expected. This is candidate rejection,
not a failing production test. Latency for incomplete/incorrect output is not
evidence of a useful speed improvement.
[Qwen author settings](https://huggingface.co/Qwen/Qwen3.5-0.8B).

Other choices retained in the evidence:

- Prefill 256 versus 512 has nearly equal long medians (2,539 versus 2,534 ms) while
  tracked peak decreases from 887 to 714 MiB. Prefill 1024 reaches 1,396 MiB without
  a useful latency gain. These are MLX allocator figures, not total app RSS.
- Cache 32/64/128/256 MiB has similar timings. Doubling 64 to 128 changed long median
  by 0.9%; this small grouped-run difference does not establish a benefit. The
  64 MiB setting limits freed-array retention, not active model memory.
- Historical BF16 weights are slower and provide no checked-fact advantage on
  the original seven cases. Historical quantized 8-bit MLX KV takes 17.18 seconds
  on the long case. Normal MLX KV remains the default.
- In the optimized x86/Rosetta CPU comparison, Q8/FP16 long medians are 22.71/30.09
  seconds, respectively. Q8 wins there; the Apple Silicon Metal choice must not
  be applied blindly to Intel CPU inference. All 28 CPU runs pass content checks.

Cleanup reference WER is retained per output. Valid punctuation/format changes
can change that score. This inventory is a regression check; it does not establish
population WER or universal accuracy superiority.

## Installation and review

The pinned public MLX artifact is byte-identical to the author-derived group64
conversion, with about 320 MiB of weights versus 462 MiB for GGUF. All weight,
tokenizer/config, LICENSE and NOTICE assets are pinned by revision, size and
SHA256. The author's full attribution is retained.
[Author recipe](https://huggingface.co/superwhisper/s1-mini),
[public conversion](https://huggingface.co/mlx-community/S1-mini-MLX-4bit).

New installs choose the recommended architecture format in the normal app cache.
Existing useful GGUF files stay usable offline; Optimize Model downloads MLX
alongside them. A real verified MLX package is installed in this machine's normal
app cache for app use. No weights or personal signing files are committed.

Downloads aggregate progress over all assets. Only a fully verified staged
directory is installed. Failed/cancelled downloads remove staging and retain the
previous install. Tests cover concurrent-operation rejection, stale callbacks,
partial packages, fingerprints and rollback. A real pinned install/delete test
passed alongside four lifecycle checks.

Review fixed prefix-buffer teardown before allocator clearing, avoided full prompt
tokenization for an already oversized input, corrected timing of asynchronous
prefill, and preserved inherited Swift compilation conditions for dependencies.
All style/structure/context combinations compare cached/uncached output, and
SHA256 checks confirm public prefix tensor bytes remain unchanged. Tests cover
reversed/concurrent requests, cancellation recovery, unload/reload and long endings.

Signed Debug suite: **652 total, 584 passed, 68 skipped, zero failed**. Signed Debug
universal build contains arm64 and x86_64. Ten selected Debug tests pass under
Rosetta, including real GGUF inference. The retained native probe builds in
Release. Package-plugin validation stays enabled.

The available hardware does not establish native Intel throughput, performance on
8 GiB/base-M Macs, minimum-macOS 14 runtime behavior, energy use or live app Stop
latency. Those remain hardware acceptance checks before broad rollout; they do
not invalidate the recorded build and model regression results.

## Reproduce and prepare the PR

Use the existing benchmark setup, ignored Team ID signing and installed app
models. Keep inference serial and avoid concurrent builds during measurements:

```sh
scripts/dev.sh signing K5Z9P4C6P2
DERIVED_DATA_PATH="$PWD/DerivedData" scripts/dev.sh build
DERIVED_DATA_PATH="$PWD/DerivedData" scripts/dev.sh test
DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only s1-runtime,s1-prepare
```

Set `S1_MLX_MODEL_PATH` / `S1_MINI_MODEL_PATH` to override model locations in
benchmarks; `TEST_RUNNER_` prefixes forward them into the normal test runner.
`s1-cpu` is the CPU precision comparison, and `s1-context` retains the parent
allocation experiment. Native quantization/prefill/cache and saved-output scoring
commands are in the [probe README](../tools/s1-mlx-probe/README.md).

[Evidence](benchmarks/s1-runtime-integration-2026-10-02.json) retains 420 paired app
outputs, 84 review outputs, 28 CPU outputs and 651 scored raw native outputs, with
configuration, hashes, completion and per-trial quality/latency. Concurrent-build
contaminated matrix timings are excluded. The seven-case prototype remains
[historical evidence](s1-mlx-evaluation.md).

[PR description and readiness notes](s1-runtime-pr.md) cover this branch's scoped
diff. No branch has been pushed and no PR has been opened.
