# S1 inference context reuse

One context belongs to the existing inference actor and its loaded model.
Generation is synchronous within that actor, so requests cannot interleave.
Successful requests synchronize and clear both KV data and token positions.
Cancelled/failed decodes discard the context; unload/model replacement and deinit
free the context before freeing its model. Prompt, greedy sampling, weights,
4,096-token context, Q8 caches and chunking remain unchanged. No cross-transcript
prefix cache or user settings are introduced.

Prewarm now retains the allocation it exercises. Its synthetic KV contents are
cleared. The next recording avoids context allocation while retaining an empty
decoder history. A failed decode invalidates preparation so the next attempt can
recreate and prepare its context.

## Verification

Fresh Team-signed Debug build and normal suite: 634 total, 563 passed, 71 skipped,
zero failed. A separate installed-model run enables all S1 lifecycle/golden tests:
27 total, 26 passed, one explicit network-download test skipped, zero failed.
Tests compare reversed request order against fresh contexts, inspect empty KV
positions, cancel after real prompt evaluation, recover on the next request,
replace model paths and check long-input endings/numbers. Benchmark script checks
pass. No model downloads occur implicitly in unit tests.

Optimized Release app and tests, M3 Max/36 GiB, five alternating trials per mode
on all seven supported authored English cleanup goldens: **70 outputs**, identical
between fresh and reused allocations on every case/repeat. Required facts and
semantic checks pass. Reference WER can differ from zero for valid formatting;
it does not change between the two allocation policies.

| Short fixture | Fresh p50 | Reused p50 |
| --- | ---: | ---: |
| Numbers/negation | 195.9 ms | 171.1 ms |
| Question | 76.9 ms | 51.6 ms |
| Correction | 86.7 ms | 60.3 ms |
| Already clean | 87.3 ms | 59.6 ms |
| Dictated instruction | 99.4 ms | 72.5 ms |
| Literal apology | 121.6 ms | 93.9 ms |

Short requests save roughly 25–28 ms. Long requests varied from 3.68 to 7.45
seconds across the two modes; no reliable long-input speedup is claimed. Model
weights stay loaded in both modes. The fresh probe also performs explicit KV
clearing, so this isolates allocation policy rather than duplicating every
instruction of the historical implementation. Chunk planning is outside the
timer; request tokenization, context allocation/release, generation and clearing
are inside. These are single-Mac diagnostic measurements, not population latency.

[Per-trial outputs, source hashes and verification](benchmarks/s1-context-reuse-2026-10-02.json)
are retained for future tuning. Reproduce using the existing benchmark setup:

```sh
DERIVED_DATA_PATH="$PWD/DerivedData" PIPELINE_BENCHMARK_ITERATIONS=5 \
  scripts/dev.sh benchmark --release --only s1-context
```

Use ignored Team ID signing (`scripts/dev.sh signing K5Z9P4C6P2`) and the installed
app cache, or set `S1_MINI_MODEL_PATH` explicitly. Keep inference runs serial.
