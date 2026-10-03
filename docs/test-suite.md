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
- Model/language availability, input-source switching and persisted settings that
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

On the same Mac and base revision `e3a2f8c`, signed Debug XCTest results changed
from **639 tests / 75 skipped / 20.177 seconds** to
**387 tests / 12 skipped / 10.562 seconds**, with zero failures in both runs.
This is XCTest execution time, not a cold build or a whole development-cycle
benchmark. Of the retained source methods, 37 additional model/benchmark methods
are excluded from ordinary test compilation. The suite size is an outcome of
removing duplication, not a quota for future regression coverage.
