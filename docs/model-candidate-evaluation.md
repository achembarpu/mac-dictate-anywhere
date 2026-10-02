# Additional model and prompt evaluation

Evaluated on 2026-10-02. Candidates are research results, not newly supported
app backends. Prefer a complete transcript over a small latency win. Use the
shared golden fixtures and WER/CER scorer; also check names, numbers, negation,
questions and final intent. Reference error alone cannot establish cleanup
quality because different punctuation or wording can be valid.

## Collection screening

The [requested collection](https://huggingface.co/collections/danielrosehill/stt-cleanup-text-postprocessing)
contains fourteen entries, including duplicate formats and narrower tasks.
Names and download counts do not establish suitability for dictation cleanup.

| Entry | Decision and evidence |
| --- | --- |
| [Qwen2-7b-cleanup](https://huggingface.co/sakusakumura/Qwen2-7b-cleanup) | Reject as a rewrite model: its card describes Japanese text-quality labels. |
| [Qwen2-7b-cleanup-short-prompt](https://huggingface.co/sakusakumura/Qwen2-7b-cleanup-short-prompt) | Insufficient documented rewrite contract or preservation evidence to justify an 8B download. |
| [S1-mini](https://huggingface.co/superwhisper/s1-mini) / [GGUF](https://huggingface.co/superwhisper/s1-mini-GGUF) | Already supported and tested with its trained prompt, greedy decoding and Q4_K_M weights. Retain. |
| [Polish Qwen normalization](https://huggingface.co/Folx/qwen3-0.6b-pl-text-normalization) | Language-specific name and no explanatory card; no basis to select for general multilingual cleanup. |
| [S1-mini LiteRT](https://huggingface.co/mlboydaisuke/S1-mini-LiteRT) | Alternate Android runtime for the existing model. Phone CPU/GPU results do not justify a Mac runtime change. |
| [disfluency-large](https://huggingface.co/DD0101/disfluency-large) | Token-deletion classifier, not full punctuation, formatting or correction. No replacement. |
| [premove-itn](https://huggingface.co/premove-ai/premove-itn) | English inverse text normalization with a Rust candidate graph and a large scorer. Author reports numeric-class regressions and substantial initialization. Consider only as a separate ITN experiment. |
| [Mend](https://huggingface.co/daltonoscar0/mend-flan-t5-small) | Tested below. Fast but loses names and meaningful apologies. Reject as a replacement. |
| [11M disfluency tagger](https://huggingface.co/stillerman/fdt-disfluency-mini-11m) | Narrow deletion/casing pass. Its card identifies noncommercial training-data restrictions; no product adoption. |
| [Mumble v2](https://huggingface.co/amitashwini/mumble-cleanup-v2) | Sparse documentation. Evaluate the documented [upstream 2-stage version](https://huggingface.co/amitashwini/mumble-cleanup-2stage) instead. |
| [Mumble 2-stage mobile GGUF](https://huggingface.co/trevornk/mumble-cleanup-2stage-GGUF) | The mobile Q4_0 speed claim is device-specific. Tested upstream Q4_K_M with its trained prompt and greedy decoding; rejected for fact losses. |
| [true-case-base](https://huggingface.co/huseinzol05/true-case-base) | Old casing-only artifact without a usable model card. No replacement. |
| [Multilingual punctuation/truecase](https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase) | Useful narrower classifier with an ONNX path. Future option for punctuation-only cleanup; does not resolve self-corrections or provide full dictation cleanup. |

## Mend

Pinned `daltonoscar0/mend-flan-t5-small` at
`230a456089ac0c03d331546a56a5ac2ed9f26271`. Followed its model-card lowercase
register and `clean up: ` prefix, greedy generation, 512 output-token ceiling.
PyTorch MPS on the M3 Max. Seven short English cases, three repeats each. The
874-token long case was explicitly excluded from this short-input probe.

All three repeats changed Mara to Maria; all three removed a literal apology.
Warm short calls were approximately 59–152 ms, but this does not outweigh the
preservation failures. Loading took 7.6 seconds, and the first decode took
1.38 seconds. These were not paired timing comparisons with S1. Do not ship
Mend or add a second cleanup pass to compensate for its errors.

`scripts/evaluate_mend.py` collects outputs without implementing a second error
scorer. The `cleanup-prompts` group scores the saved outputs against the exact
shared manifest hash. Raw results and scored rows are retained with the
benchmark evidence. Normal Hugging Face model cache is used; the app currently
has no native T5 backend.

## External prompts

Pinned [Rosehill's prompt repository](https://github.com/danielrosehill/STT-Basic-Cleanup-System-Prompt)
at `1206cb8a2eb60ff595d97589a2cc88caea71c3bd`. Basic cleanup principles overlap
with the app's existing rules. The complete prompt additionally interprets
spoken editing instructions and inserts structure. That conflicts with this
app's rule that questions and instructions inside a transcript remain content.
No license file was present in the inspected revision; whole prompt text is
kept in the external reference clone, not copied into the product.

The research harness compares an explicit local prompt file verbatim with the
production prompt on the same installed Ollama weights. It alternates order
across repeats, reports fact and semantic failures, and checks completion.
A completed benchmark run does not imply that a candidate passed quality.

Both Basic and Complete were evaluated on all eleven fixtures, paired against
the app on `qwen3:4b-instruct`. Each had one incomplete generation, eight
semantic misses and four required-fact misses. Basic refused the dictated
request to inspect code and removed Elena; Complete answered a question and
lost Chinese details. Both retained superseded Monday wording. Do not port
either whole recipe. Keep our question/instruction-as-content, same-language,
vocabulary, final-intent and strict-response rules. The principles about filler
words and conservative punctuation are already implemented independently.

These compare complete recipes, including the app's vocabulary and JSON
envelope versus a raw text-only external prompt. They do not isolate one
sentence's causal effect. Reference error and quality checks are retained
separately, including the app's later nonzero long-reference error.

## Mumble

Pinned upstream `amitashwini/mumble-cleanup-2stage` at
`e7ce94746f0e2d2d172d0ece000725c81ae3dc9b`; Q4_K_M weight SHA256
`fc6409457b8db4b37ef6184ae720a9bffe4df5ac506979ed83d0d53faab158ab`.
The normal Ollama cache contains the exact filename tag
`hf.co/amitashwini/mumble-cleanup-2stage:mumble-cleanup-2stage-q4km.gguf`.
The shorthand `:Q4_K_M` did not resolve; do not confuse tag spelling with the
actual quantization. Apache-2.0 model, English only.

Eight English cases, two order-alternated repeats, using the author's exact
prompt, greedy decoding and conservative 512-byte chunks. All sixteen author
outputs completed, but six required facts were lost. Nadia became Nina in both
already-clean trials, and the long case lost Priya and Tuesday. The long output
also repeated and invented text, with 44–60% reference error. Short requests
were fast; correctness rules out replacement or a native app integration.

The server's ChatML template and EOS token were checked against the author's
CLI recipe. The generic app instruction/schema recipe is also a poor fit: one initial
request looped to a 120-second timeout. This uncovered a product fix for
explicitly advertised completion-only models: bound generation using the
reserved output budget. The bounded rerun completed or rejected short requests
in 0.31–0.93 seconds and preserved original input on failure. This protects the
app; it does not turn this fine-tune into a general JSON cleanup model.

## Phonon-2

Pinned [weights](https://huggingface.co/FermionResearch/Phonon-2) at
`ca1bef26bcd8ef4a7e16d0636d8a77bb25e298ee`, reference
[repository](https://github.com/fermionresearch/phonon) at
`ba0339cb01d6103a4c632cfc8c7744c23c1587cb`, and `fermion-research==0.2.7`.
The model card describes a 164 MB English Parakeet derivative. Its published
5.21% mean WER and M5 throughput are author results, not measurements on our Mac.
Weights are CC-BY-4.0; runtime source is Apache-2.0.

The actual MLX runtime defaults to `tdt16,dense16`: batched GPU decoder steps
and an encoder expanded to FP16. Thus tiny stored weights do not mean equally
tiny resident GPU memory. `tdt16` alone retains packed encoder weights. In this
version, hotword arguments are accepted but not wired into the Phonon-2 decoder.
Its `truncated` field cannot trigger with the artificial frame-derived budget;
use full reference comparison rather than treating that field as completeness
proof. Mac Intel speech is unsupported by the inspected loader.

Measured 21 decodes on seven English fixtures for each of the default
`tdt16,dense16` and packed `tdt16` paths. Both had identical WER on every fixture
and repeat. Four cases were zero; three measured 9.86%, 5.56% and 5.17%. Against
the retained native Parakeet v3 results, one case improved and two worsened;
there is no across-the-board accuracy win. Both use the same reference scorer.

Warm default HTTP requests took approximately 38–341 ms; first decode 3.22 s
after a 9.28 s model load. Three direct 72.67-second decodes measured 220× real
time for the default and 141× for packed. Peak MLX memory fell from 1.92 to
1.41 GB with packed; standalone peak RSS was 3.09 GB for both. Keep the faster
author default for this M3 Max if developing an integration. Packed is a useful
memory tradeoff to evaluate on smaller Macs, not a user-facing decoder tuner.

Recommendation: retain as a strong compact English backend candidate for a
separate integration. This requires a new native runtime/backend to embed in
the app. The weights
are not a drop-in replacement for FluidAudio's Core ML models. Evaluate the
local HTTP runtime using `external-asr-quality` when changing runtimes/settings.
Streaming, long-recording behavior, vocabulary biasing, cancellation and native
packaging need separate acceptance checks for a product backend.

All measured rows, runtime versions/digests and memory probes are retained in
[the evidence report](model-stack-benchmark-results.md) and its JSON. The
evaluation servers were stopped; caches remain available for future work.

## Reproduction

Use `scripts/dev.sh benchmark --release --only cleanup-prompts` with
`PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH` and
`PIPELINE_BENCHMARK_CLEANUP_MODEL` to evaluate a local external prompt. For Mumble,
select its exact Q4_K_M filename tag, set `PIPELINE_BENCHMARK_CLEANUP_GREEDY=1`,
`PIPELINE_BENCHMARK_CLEANUP_INPUT_BYTES=512` and
`PIPELINE_BENCHMARK_LANGUAGES=en`. The byte bound is conservative for the author's
short-input training limit. Do not apply those overrides to arbitrary models.

For saved Mend outputs, select `PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH` instead
of a prompt path. For local speech, run `external-asr-quality` with
`PIPELINE_BENCHMARK_ASR_URL=http://127.0.0.1:8010/v1`,
`PIPELINE_BENCHMARK_MODEL=phonon-2` and `PIPELINE_BENCHMARK_LANGUAGES=en`.
The harness launches no server and downloads no weights implicitly. Keep model
inference runs serial; use an explicit Team ID signing configuration.
