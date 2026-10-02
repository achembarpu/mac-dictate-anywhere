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
