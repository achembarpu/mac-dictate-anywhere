# Run S1 cleanup natively with MLX on Apple Silicon

Context reuse saved 23–26 ms, but S1 still spent most of its request time on
prompt evaluation and autoregressive decoding. Add official native Swift MLX
inference on Apple Silicon and retain llama.cpp CPU inference on Intel. New
installs select the recommended runtime automatically; existing GGUF installs
remain usable offline and can install MLX through Optimize Model.

## Implementation

- Author-converted 4-bit/group64 weights with original BF16 arithmetic, trained
  greedy prompt, normal KV, 256-token prefill and a 64 MiB allocator cache.
  Copy only the fixed 51-token public prefix; controls/transcripts use fresh KV.
- Actor operation gate serializes loading, tokenization, preparation, requests
  and unload. Require EOS, join GPU work on cancellation/teardown and retain no
  transcript history. Shared lossless chunking/completeness fallback stays active.
- Prepare graph/tokenizer, public prefix, short and batched prefill and decoding
  before use. Runtime identity changes invalidate preparation through the app's
  existing startup/settings/recording lifecycle.
- Intel uses Q4_K_M GGUF, Q8 KV and physical cores capped at eight; the retained
  Apple Silicon Metal GGUF path uses measured faster FP16 KV. Intel never
  initializes an MLX graph. No hardware/decoder tuning controls are added.
- Pin MLX Swift 0.31.4, LM 3.31.3 and Transformers 1.3.0 with normal package
  validation. Install pinned assets, including LICENSE/NOTICE, with SHA256,
  staged verification, aggregate progress and cancellation/rollback protection.
- Add 14 authored stress references and original-text safeguards for lost
  numeric minus signs and literal chat markers. Keep app/native benchmarks,
  exact source/model/configuration hashes and rejected variants for future work.

## Performance and quality

Optimized signed app on one M3 Max / 36 GiB / macOS 26.7.1: five alternating
trials, 21 authored English cases and four modes, **420 outputs**. Timers include
request tokenization, generation, normalization, safeguards and GPU drain;
exclude model loading/preparation. Cached/uncached MLX output matches exactly;
zero checked fact/meaning misses. The model/format differs from GGUF, so these
measure the selected runtime stack rather than isolating a single kernel.

| Case | Parent reused GGUF/Q8 p50 | Native MLX p50 | Lower latency |
| --- | ---: | ---: | ---: |
| Numbers/negation | 180.8 ms | 103.7 ms | 43% |
| Question | 54.2 ms | 37.3 ms | 31% |
| Spoken correction | 63.2 ms | 42.0 ms | 34% |
| Already clean | 63.4 ms | 42.0 ms | 34% |
| Dictated instruction | 77.1 ms | 49.9 ms | 35% |
| Literal apology | 99.7 ms | 59.3 ms | 41% |
| Long complete ending | 3,858.0 ms | 2,559.4 ms | 34% |

Prepared first use on a separate invoice input is 73.4–73.9 ms, matching steady
requests at 73.5–74.0 ms. Preparation takes 516–538 ms; graph-cold first use was
968 ms. This moves work into preparation; OS caches were not flushed. Public
prefix caching saves about 5–6 ms on most short cases, 18.9 ms on numbers,
with no consistent long gain. Legacy Metal FP16 KV is 8–10% faster than Q8 here.

Reject group32/128, FP16 arithmetic and quantized KV variants that lose meaning
or slow decoding. Reject S1 8-bit and a smaller general-purpose cleanup model
on their measured quality/performance tradeoffs. A later **192-output** native
dependency screen rejects MLX 0.32.3 / LM 3.32.3: long p50 2.556 s becomes
3.215/3.233 s; conservative TurboQuant takes 5.417 s. Keep the faster pinned
versions. Final retained app check: 126 outputs, exact cache agreement, zero
checked meaning misses, numbers 103.4 ms and long 2.529 s.

## Shared research and benchmarks

Carry the parent follow-ups without new production STT defaults: 23 licensed
speech goldens, Whistle tiny CPU, native Phonon-2, Moonshine streaming, Qwen3-ASR
4/8-bit and quiet-acoustic collectors, raw scores and provenance. Failed outputs
remain in the evidence; rejected variants stay outside the active matrix.

Whistle trades accuracy for its tiny CPU footprint. Phonon's long-file speed
and smaller cache do not offset its read-speech regression. Moonshine fails
quiet/session completion gates. Qwen 8-bit repairs mixed-language translation
but still loses quiet negation and takes 3.4–6.2× native SenseVoice time on the
two diagnostic cases. Gain4 helps quiet raw WER but does not restore negation;
product gain remains research-only. Exact CSV fixture/mode selection avoids
unnecessary full sweeps. Models remain in persistent caches for future use;
research-only models are not app options.

The runtime audit confirms llama.cpp b10549 already uses Flash Attention AUTO
and supported GPU offload; Metal and MLX are separate implementations. Core ML
STT retains each model's documented placement/correct architecture fallback.
No newer dependency or low-level knob is added without a measured benefit.

## Validation and limits

Latest fresh normal Team-signed Debug at `ca30de5`: **656 total, 574 passed,
82 skipped, zero failures**; parent `af5183f` passes639/564/75/zero. Both builds
pass. [Final audit](model-stack-readiness.md) records checks and hashes.
Historical installed-model suite:
652 total / 584 passed / 68 skipped / zero failures. Signed universal Debug
build contains arm64/x86_64; ten selected real-model/runtime tests pass under
Rosetta. Native Intel throughput was not measured on actual Intel hardware.

420 paired app outputs, 84 final regression-review outputs, 28 optimized
x86/Rosetta CPU outputs and 651 raw native outputs are retained in
[the integration report](s1-runtime-integration.md) and
[artifact](benchmarks/s1-runtime-integration-2026-10-02.json).
The [dependency screen](s1-mlx-upgrade-screen.md) retains rejected updates and
126 final app outputs. Latest shared Release/scorer/script/Python/integrity
checks pass; expected Moonshine candidate failures are retained separately.

Review/fix rounds cover ownership, public-prefix immutability, reversed and
concurrent requests, cancellation/recovery, teardown ordering, EOS/output
limits, runtime selection and installation rollback. Product source hashes
remain tied to measured evidence. Normal package/macro validation stays enabled.

The guards cover observed sign/marker failures, not arbitrary semantic loss.
No population accuracy, actual Intel/base-M/8GiB/minimum-macOS-14 performance,
whole-system RAM/energy or live microphone/Stop claim. Additional hardware
acceptance is needed before asserting performance across those devices.

## Stack and publication

This branch started on `feature/model-aware-transcription` at `d398ea7` and
carries later shared follow-ups by cherry-pick. Use that parent as the PR base,
and restack onto its latest tip before opening a three-dot PR to avoid repeated
shared changes. Rebase onto the merged default branch when the parent lands.
Both branches remain local; no push, PR, merge or history rewrite was performed.
