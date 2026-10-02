# Model stack follow-up evidence

M3 Max, 36 GiB, Mac15,10, macOS 26.7.1 (25G241), 2026-10-02. Benchmarks use
Team-signed Release products with both app and XCTest optimized. The final
reviewed source is `f951291`; source, fixture and retained log hashes, model
digests, runtime versions, per-trial rows and rejected variants are in
[the measured JSON](benchmarks/model-stack-defaults-2026-10-02.json).
Earlier exploratory runs did not capture every per-run source hash; the JSON
clearly distinguishes final source hashes from historical results.

## Verification

Full Team-signed Debug: **630 tests, 584 passed, 46 skipped, zero failed**.
Application Swift warnings are errors. Installed recovery ASR, Mandarin,
Nemotron and S1-mini opt-ins were enabled. Skips include explicit benchmark and
hardware opt-ins. Development-script architecture, clean safety, group/signing
selection and golden/candidate environment forwarding checks passed.

The prior native speech results remain applicable: 270 decodes across ten
models, plus 220 optimized ANE/GPU comparison decodes. This follow-up does not
change those FluidAudio decoder or hardware policies. See
[model-aware results](model-aware-transcription-results.md) and
[hardware defaults](model-hardware-defaults.md).

## Production cleanup probes

Eleven authored references cover English, German, Chinese and Dutch, including
names, numbers, negation, questions, self-corrections, vocabulary, meaningful
apologies, instructions as content and long endings. Required-fact checks and
desired cleanup edits are separate. Returning the original is reported, not
counted as proof of successful transformation.

| Path | Observed result | Timing / qualification |
| --- | --- | --- |
| S1-mini, seven English cases | Required facts and desired cleanup checks passed. | Short calls 81–231 ms; long case 3.84 s. One run per case. |
| Ollama Qwen3:4b-instruct, 33 trials | Zero required-fact or semantic misses. Long reference error zero in these three trials. | Short median 460 ms; long 11.1–12.2 s. Later prompt-paired baseline runs had long reference error 8.44% and 0%; do not claim perfect long-text fidelity. |
| Portable API, same Qwen weights, 33 trials | Required facts passed; two unresolved-correction misses. | Long 10.4–11.8 s, reference error 0–8.73%. This is Ollama's compatible endpoint, not LM Studio. |
| Llama3.2:3b, 27 trials | Lost Tuesday in all three correction trials. Not recommended for this cleanup workload. | Preserving server sampling fixed the prior long greedy loop; long calls 8.4–8.7 s. |
| Mandatory Qwen3:4b Thinking | Ten short cases kept checked facts; long request timed out. Poor interactive fit. | Short 37–96 s; median 63.4 s. Keep its real preset; do not invent a thinking-off flag. |
| Apple Intelligence, paired eleven cases | Required facts passed; two semantic misses, matching the frozen baseline. Chinese retained the original on a typed response failure. | Short path unchanged. The 683-word long case takes 15.1 s versus 9.8 s for the frozen baseline; candidate reference error 1.89%. |

The Apple context case spans 36 independently numbered paragraphs, three invoice
batches and three verification phrases. Final output preserves all checked
occurrence counts and the ending, with reference error **0.094%** in **48.5 s**.
Six passages retain their source because the model removed numeric headings.
This is a preservation fallback, not successful cleanup of those passages.
The numeric guard does not prove preservation of every name or negation.

Rejected Apple alternatives remain in the JSON. A smaller plain-text recipe
regressed on multilingual/long inputs. A three-session long transform omitted
about 35% of the context case. Adjacent paragraph pairs passed that larger case
but lost roughly 26.5% on the smaller long reference. Independent paragraphs
still dropped record labels; stronger instructions did not repair it. Retain
fresh sessions and the source-preserving numeric gate. Correctness costs extra
long-input latency; no universal cleanup speedup is claimed.

Ollama's completion-only capability list now also enables the input-derived
output bound. Mumble's generic schema request previously generated tens of
thousands of tokens and timed out at 120 s. The bounded rerun returned or
rejected short calls in 0.31–0.93 s. Long generic calls remain poor fits and
retain their original input. Unknown/reasoning metadata retains natural EOS.

## Apple Speech

Twenty-four fresh-session decodes across twelve English, Chinese and German
fixtures completed. Every fixture had identical WER/CER in both sessions.
Four short English fixtures had zero WER. Other English cases measured 5.63%,
5.56% and 2.87%; Chinese 0%, 0% and 1.92% CER; German 5.56% and 0% WER.
Initial Chinese/German asset preparation took approximately 8 seconds; fresh
prepared sessions were generally 25–30 ms thereafter.

Asset installation was explicitly enabled and used Apple's normal cache.
Dutch requests failed with the framework's asset-unavailable error; two
fixtures were skipped and cannot support an Apple Dutch quality claim. Keep
the framework's progressive transcription/compute policy, preparation API,
contextual vocabulary and finalization through the last sample.

## Additional candidates

[The screening report](model-candidate-evaluation.md) covers all fourteen
collection entries, the two prompt recipes and Phonon-2. Measured outcomes:

- Mend: 21 completed short outputs; six checked fact losses. Mara became Maria
  and meaningful apologies disappeared in all three repeats. Reject.
- Mumble author recipe: sixteen completed outputs with conservative chunks and
  greedy decoding; six fact losses, including Nadia becoming Nina and missing
  long-text names/corrections. Reject, despite fast short calls.
- Both Rosehill prompt recipes: eleven paired cases each; candidate protocol
  and quality failures. They answered or refused dictated content, left old
  corrections, or lost multilingual details. Retain the app's content rules.
- Phonon-2: 21 English decodes for each of two encoder configurations. All
  repeats and both configurations had identical per-fixture WER. Four cases
  were zero; the other three were 9.86%, 5.56% and 5.17%. Compact English
  candidate, not an automatic accuracy upgrade over native Parakeet.

For Phonon, warm default HTTP requests were approximately 38–341 ms. First
decode was 3.22 s after a 9.28 s load. On the 72.67-second boundary file, three
warm direct decodes averaged approximately 0.330 s / **220× real time**.
Packed encoder decoding averaged 0.515 s / **141× real time**. Peak MLX memory
was 1.92 versus 1.41 GB; standalone process peak RSS was 3.09 GB in both probes.
These are runtime measurements, not whole-app memory or live dictation latency.
An idle evaluation server was resident during each standalone memory probe;
there was no concurrent model inference. File/HTTP and native live-replay work
are different paths, so no direct native speedup ratio is asserted.

## Context reuse and native runtime follow-up

[S1 context reuse](s1-context-reuse.md) retains one cleared actor-owned allocation
per loaded model. Seventy paired outputs are identical, with roughly 23–26 ms
saved on short requests. Fresh signed Debug has 636 tests, 563 passed, 73 skipped,
zero failed; an installed-model S1 run has 26 passed and one download test skipped.

[Complete-file ASR comparison](phonon-file-comparison.md) adds 210 native and
21 Phonon trials through comparable whole-file paths. Phonon and v3 take about
0.33 s on the 72.67-second boundary file; Ultra/v2/110M are faster there. This
replaces speculation based on incomparable live-preview timing.

[Native S1 MLX exploration](s1-mlx-evaluation.md) retains a runnable locked Swift
package, Python reference collector and 147 completed outputs with shared fact/
meaning checks. Native 4-bit is promising; Python and quantized native KV paths
are slower. Production backend integration remains a separate acceptance task.
These later reports retain their own source and runtime hashes; the historical
follow-up measurements above are not relabeled as current-source reruns.

## Limits and reproducibility

Use the existing `scripts/dev.sh benchmark --release --only GROUP` workflow.
The [fixture inventory](../Dictate%20AnywhereTests/Fixtures/Golden/README.md)
and [benchmark guide](performance-benchmarking.md) describe provider selection,
asset opt-ins, source attribution and shared scoring. Research uses explicit
local prompt/result files or loopback servers; it starts no service or model
download implicitly. Run model inference serially.

These are small regression probes, not population WER or established p95.
Cleanup WER can penalize legitimate alternatives and exceed 100% when a model
inserts an answer. Fact checks are useful but incomplete. No billable cloud
accuracy, every-Mac performance, energy or microphone/Bluetooth UI latency
claim. Generic cloud defaults and response integrity are covered by contracts.
Phonon and Mend are evaluation runtimes, not native app backends. Models already
supported by the app were downloaded into its normal persistent caches; Ollama
models are also available to the app's model picker. No weights, credentials
or personal signing configuration are committed.
