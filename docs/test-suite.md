# Test suite

Run the deterministic app suite with Team ID signing:

```sh
scripts/dev.sh signing K5Z9P4C6P2
DERIVED_DATA_PATH="$PWD/DerivedData" scripts/dev.sh build
DERIVED_DATA_PATH="$PWD/DerivedData" scripts/dev.sh test
scripts/dev_test.sh
```

Use a stable DerivedData directory per worktree. Ordinary build and test commands
share the project's Debug compilation conditions, avoiding a needless app rebuild
between them. Keep `Config/Signing.local.xcconfig` ignored.

## Coverage that earns its cost

Keep tests that can detect a distinct user-visible failure or a broken external
contract. The retained suite covers:

- Recording startup, cancellation, late results, continuation and shutdown races.
- Audio loss, final tails, repeated speech, quiet-speech policy and bounded buffers.
- Recovery durability, expiry, retry, failed cleanup and preservation preferences.
- Cursor capture, stale accessibility ranges, process identity, list renumbering,
  formatting, CJK seams, proper names and complete transcript preservation.
- Secure-field and remote-context privacy, provider request encoding, error handling
  and rejection of truncated or malformed model output.
- Model/language availability, incomplete MLX packages, interrupted installation,
  runtime output safety, input-source switching and persisted settings that
  affect these workflows.
- Overlay observation dependencies, display identity and delayed-dismissal races;
  one constrained shortcut layout, actual color contrast and bundled font loading.
- Independent golden references, their hashes, audio format and scorer correctness.
- Development command selection, signing, environment forwarding and safe cleanup.

Use fixture tables for related boundary cases that share setup and behavior. Keep
asynchronous lifecycle regressions separate when their ordering and failures differ.
Do not add tests for raw enum literals, default constants, copied formulas,
self-confirming flag checks, view construction alone, or screenshots without a
comparison oracle. Assert the observable result at the consumer instead.

## Expensive checks

Model-backed tests and benchmark workloads compile only with `PIPELINE_BENCHMARK`.
They are selected by `scripts/dev.sh benchmark --only GROUP`; bare `benchmark`
fails before building. `--only all` is available for a deliberate broad run.
Use the [benchmark guide](performance-benchmarking.md) to choose the smallest
relevant group and fixture. Ordinary tests never load or download speech/cleanup
models. Browser, live-provider and real microphone checks retain explicit opt-ins
because they validate boundaries the deterministic suite cannot exercise.

Deleted screenshot exporters, direct SDK smoke checks, synthetic Mandarin fixtures
and frozen implementation comparisons had no unique regression oracle or duplicated
production-path/golden checks. Historical benchmark measurements and source hashes
remain in Git and `docs/benchmarks/`; they are evidence, not recurring workloads.

## Verified reduction

The approved final base, `feature/s1-mlx-integration` at `4206ac5`, has 656 test
methods. The retained signed Debug run passes **394 tests / 12 skipped / zero
failures**, with **9.169 seconds** of XCTest execution. Another 45 model/benchmark
methods compile only for explicit benchmark runs. The latest base's prior signed
[verification](s1-runtime-pr.md) reports 656 tests / 82 skips / zero failures.

Before the newer MLX base became available, the same-Mac initial comparison on
`e3a2f8c` passed 639 tests / 75 skips in 20.177 seconds, then passed its reduced
387 tests / 12 skips in 10.562 seconds. These are XCTest execution times, not cold
build or whole-development-cycle timings; no timing comparison against an
unpruned MLX base was run in this audit.

The focused optimized Debug run also passes all 18 selected workload and installed
S1 lifecycle tests, with no skips. This includes actual GGUF/MLX request isolation,
cancellation, long-input preservation and cache equivalence. Suite size is an
outcome of removing duplication, not a quota for future regression coverage.

An optimized Release run passes the overlay workload, S1 runtime selection and one
MLX golden fixture (3 tests, no skips or failures). The shell command checks and
both Python collector tests also pass. Browser, live-provider, microphone and
other ASR model runs were not enabled during this audit.
