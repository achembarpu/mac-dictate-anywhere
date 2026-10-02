# S1 MLX dependency screen — 2026-10-03

Keep production MLX Swift **0.31.4 / LM 3.31.3**, 4-bit/group64 author weights,
original BF16 arithmetic, normal KV, public prefix, 256-token prefill and a
64 MiB allocator cache. The newer libraries build successfully, but the tested
configurations slow S1 on this M3 Max. No dependency or production runtime
change from this screen is shipped.

## Measured gate

Same installed model and 21 authored English references; three Release trials
per fixture. Model inference runs serially without overlapping owned builds.
These are grouped dependency runs, not alternating runs or population benchmarks.
The native collector includes tokenization/decode and excludes app safety gates.

| Native runtime | Numbers/negation p50 | Long input p50 | Peak MLX allocation |
| --- | ---: | ---: | ---: |
| Core 0.31.4 / LM 3.31.3 | 102.8 ms | 2.556 s | 713.9 MiB |
| Core 0.32.3 / LM 3.32.3, balanced prefill | 112.0 ms | 3.215 s | 740.9 MiB |
| Same update, remainder prefill | 112.1 ms | 3.233 s | 759.0 MiB |
| Same update, conservative `turbo0v4` | Not run after long speed gate | 5.417 s | 759.1 MiB |

Balanced prefill is approximately 4–9% slower on most short cases and 25.8%
slower on the long case. Remainder does not recover the performance. TurboQuant
fails the initial long-input gate, so no wider accuracy matrix is run.
Peak MLX allocation excludes other framework/process memory; it is not RSS or
an energy measurement. This host has 36 GiB RAM and macOS 26.7.1/Xcode 27.

All **192 native outputs reach EOS**. Twenty of 21 normal-KV fixture outputs
match the old decoder exactly. The updated decoder preserves the negative
amount as “minus $42.75”; the old raw decoder loses its sign. The existing app
sign guard already preserves the original in that case. The lexical golden
assertion flags both strings because it expects `minus 42`/`-42`; the new
wording preserves meaning. Both raw decoders also remove the literal chat
marker in its regression case, which the existing app guard protects.

The retained production app passes **126 outputs** across the 21 cases, three
trials and cached/uncached MLX modes. Outputs match exactly with zero checked
fact/meaning misses. Current cached p50 is 103.4 ms on numbers/negation and
2.529 s on the long input. Its process peak RSS is 554.1 MiB, including the
app/test host. Do not compare that directly with native MLX allocation above.

## Source audit and migration traps

[Core 0.32.3](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3) fixes
an earlier 0.32 launch problem on older macOS. [LM 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3)
adds cache, cancellation and loading improvements. Its compiled Qwen3.5 paths
do not apply to S1's Qwen3 architecture. Per-token cache fencing, autorelease
pool draining and periodic allocator clearing are plausible contributors to
the measured overhead; their individual costs were not isolated.

[PrefillParameters](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/PrefillParameters.swift)
defaults to balanced chunking; `.remainder` restores the prior chunk boundaries.
Both were tested. Cache construction now throws. More critically,
[`Stream()`](https://github.com/ml-explore/mlx-swift/blob/0.32.3/Source/MLX/Stream.swift)
now creates a new stream. A future migration must use
`Stream.defaultStream.synchronize()` to drain the graph's actual default stream.
Keeping the old initializer would weaken preparation/cancellation/teardown.

Normal package/macro validation stays enabled. The new package declares CUDA
plugins only on Linux. Swift Syntax resolves to 603.0.2; app and probe keep
their old locked graphs after this rejected screen. Native Intel, minimum
macOS and base M/8 GiB performance were not remeasured because product behavior
and the dependency graph remain unchanged. Prior universal/Rosetta evidence
and the CPU runtime selection remain applicable.

## Reproduce and retained evidence

The [structured report](benchmarks/s1-mlx-upgrade-screen-2026-10-03.json) retains
192 raw outputs, their shared Swift scores, 126 app outputs, dependency locks,
configuration, source/log hashes and per-case medians. The
[candidate probe patch](benchmarks/mlx-upgrade-candidate.patch) applies only to
the standalone probe; `git apply --check` verifies it against this branch.
Apply it in an isolated worktree to recreate the rejected upgrade. Use the
existing [probe commands](../tools/s1-mlx-probe/README.md); changing its prefill
chunking to `.balanced` recreates the balanced variant. The last positional
argument `turbo0v4` selects the conservative candidate, and
`PIPELINE_BENCHMARK_FIXTURE=long-complete-ending` limits the initial speed gate.
Do not apply this patch to production defaults.

The existing app benchmark can now select only the needed backends:

```sh
PIPELINE_BENCHMARK_S1_MODES=mlx,mlx-uncached \
  PIPELINE_BENCHMARK_ITERATIONS=3 DERIVED_DATA_PATH="$PWD/DerivedData" \
  scripts/dev.sh benchmark --release --only s1-runtime
```

It validates unique mode names, loads only requested formats, retains exact
prefix-output and quality assertions and records process CPU/RSS counters.
The default still runs all four original modes. References were not changed
to match a decoder, and the rejected variants stay outside the active matrix.

Fresh detached verification at `5019e19`: normal Team-signed Debug build succeeds;
**654 tests, 574 passed, 80 skipped, zero failures**. Model/benchmark opt-ins explain
the skips. The separate optimized app and saved-output checks above pass.
