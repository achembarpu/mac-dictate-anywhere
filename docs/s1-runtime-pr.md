# Suggested title

Run S1 cleanup natively with MLX on Apple Silicon

# Description

S1 cleanup still spent most of its time evaluating prompts and decoding after
context allocation reuse. Add official native Swift MLX inference on Apple
Silicon while retaining llama.cpp CPU inference on Intel. New model installs
select the recommended runtime automatically; existing GGUF installations can
use Optimize Model without losing their usable download.

The measured defaults keep the author's greedy cleanup recipe and use verified
4-bit/group64 weights, normal MLX KV, 256-token prefill and a copied fixed public
prompt cache. The actor serializes graph ownership, requires EOS, drains cancelled
GPU work and retains no transcript history. Shared chunking/fallback rules remain
in force. Preparation covers both short and batched inference before usage.
Legacy Metal GGUF uses measured FP16 KV; Intel CPU keeps Q8 KV and physical-core
thread selection. There are no new low-level product configuration controls.

Model packages pin and verify every asset, including the author's LICENSE/NOTICE,
with aggregate progress and staged installation. Add 14 stress references and
guards for lost numeric minus signs and literal chat markers. Preserve runnable
app/native benchmarks and per-output evidence. Reject faster quantization variants
that lose a negation and the general-purpose Qwen candidate that fails cleanup.

On one M3 Max, five alternating trials per case give 31–43% lower latency across
the six original short fixtures and 34% lower latency on the long case versus the
parent's reused GGUF/Q8 path. Numbers/negation drops from 181 to 104 ms; the long
case drops from 3.86 to 2.56 seconds. Prepared first use matches steady requests at
about 74 ms on a separate short invoice input. These are cleanup measurements,
not end-to-end dictation latency or a claim about every supported Mac.

Validation:

- Signed Debug suite: 652 tests, 584 passed, 68 skipped, zero failures.
- Signed universal Debug build includes arm64 and x86_64; ten selected real-model
  and runtime-selection tests pass under Rosetta.
- Paired optimized app benchmark: 420 outputs over 21 English cases and four modes,
  zero checked meaning/fact misses; cached/uncached MLX output matches exactly.
- Final 84-output review verifies explicit factual-loss regression assertions.
- Real pinned-model installation and rollback/cancellation/package checks pass.
- Retained native Release probe, 651 scored raw native outputs and 28 optimized
  x86/Rosetta CPU comparisons. Qwen protocol-score failure is expected rejection
  of unfinished candidate outputs; Qwen is not added to the app.

The diff stacks on `feature/model-aware-transcription` at `d398ea7`. Keep that
branch as the PR base until it merges, then rebase onto the merged default branch.
Full results and limitations are in [the integration report](s1-runtime-integration.md)
and [raw evidence](benchmarks/s1-runtime-integration-2026-10-02.json).

# Readiness review

Code review and fix round completed. Verified request isolation, prefix byte
immutability, cancellation, teardown ordering, complete-response handling,
installation migration and architecture selection. Normal package-plugin
validation remains enabled. No outstanding code-review blocker was found.

The available Mac cannot establish native Intel throughput, 8 GiB/base-M behavior,
minimum-macOS 14 runtime behavior or energy/live Stop latency. Those are explicit
hardware acceptance limits. The raw S1 model also retains semantic failure modes;
the new guards cover the observed sign/marker cases, not arbitrary meaning loss.
The 21-case authored inventory is a regression gate, not population WER evidence.

Publication remains a separate user action. This work is committed locally;
the branch has not been pushed and no PR has been opened.

## Active STT/runtime follow-up

This branch also carries the shared Whistle screening/golden increment from the
model-aware branch. Five new audio/text pairs broaden voices, names, numbers
and quiet/noisy acoustic controls. The collector and process CPU/RSS counters
use the existing shared Swift scorer and benchmark groups. No Whistle app
backend or new default is added by this increment.

Whistle: 14.73% WER on nine independent English clips versus v3's 5.36%, with
summed warm times 0.485 versus 0.658 s. Its tiny CPU archive is attractive;
quality trails the native models, while one quiet control is substantially
better. Details and all 136 outputs are in [the report](whistle-evaluation.md)
and [structured evidence](benchmarks/whistle-screen-2026-10-03.json). Resource
counters exclude Core ML helpers/accelerator allocations and do not prove
whole-model RAM or energy savings.

The propagated increment passes normal Team-signed Debug build/test from a
fresh detached checkout: **653 tests, 573 passed, 80 skipped, zero failures**.
The parent runs 637 tests, 564 passed, 73 skipped, zero failures; its focused
Release scorer/native comparisons pass. Existing S1 runtime results above
remain historical measurements of the prior reviewed implementation.

The wider follow-up is active. A native dependency screen tested MLX 0.32.3 /
LM 3.32.3 with balanced and remainder prefill, then stopped one conservative
TurboQuant variant after its long-input speed gate. The new normal-KV paths
are 4–9% slower on most short inputs and 26% slower on the long case; TurboQuant
is about twice as slow. Keep the faster 0.31.4 / LM 3.31.3 pins. Preserve all
192 raw/scored outputs and the standalone candidate patch for future work.
Normal validation remains enabled. The update also requires a real stream API
migration; its `Stream()` now creates a new stream rather than selecting the
default graph stream.

The focused app gate now selects only requested modes and records process
CPU/RSS, avoiding unchanged backend runs. Its 126 outputs over 21 cases have
zero checked fact/meaning misses and exact cached/uncached agreement. Current
cached p50 is 103.4 ms on numbers/negation and 2.529 s on the long case. Fresh
normal Team-signed Debug verification at `5019e19`: **654 tests, 574 passed,
80 skipped, zero failures**. Runtime defaults and Intel selection are unchanged;
no new universal or native Intel speed claim follows from this screen. See
[the upgrade screen](s1-mlx-upgrade-screen.md) and
[retained evidence](benchmarks/s1-mlx-upgrade-screen-2026-10-03.json).

The shared acoustic screen now separates quiet Float32 amplitude sensitivity
from PCM16 quantization. It retains 105 outputs across v3/110M and two speakers.
On the first clip, quiet Float32 WER rises from 11.76% to 58.82% for v3 and from
0% to 100% for 110M; a 4× boost restores their original outputs. The second
speaker's name accuracy improves at 4×, but stronger gains do not help. This is
test-only evidence: live/VAD and natural-noise checks remain pending before any
product gain. See [the acoustic report](tdt-acoustic-screen.md).

Fresh normal Team-signed Debug verification at `f1405a1`: **655 total, 574 passed,
81 skipped, zero failures**. The parent at `638e7c0` passes 638 total / 564 passed /
74 skipped / zero failures. Both focused Release acoustic runs and script checks
pass; weight and build/test log hashes are retained. Useful STT variant screens
and the wider runtime audit remain active. Workspace research:
`docs/stt-runtime-research.md`.
