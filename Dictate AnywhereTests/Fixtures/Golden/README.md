# Human speech golden references

These 20 audio/reference pairs are test resources, also available to
`scripts/dev.sh benchmark`. No speech model generated or corrected the references.
The manifest records language, metric, sample count, pinned source, source IDs,
transformations, and SHA-256 hashes. Ordinary tests validate every pair without
model inference, downloads, microphone access, or cloud calls.

| IDs | Coverage | Source |
| --- | --- | --- |
| `golden-en-1` … `golden-en-6` | Six English readings, 4.8–29.4 s, including proper names | LibriSpeech validation subset, first six records |
| `golden-en-boundaries` | 72.665 s, multiple decoder windows and shifted speech seams | Those six readings joined with 200 ms silence after each |
| `golden-en-fleurs-1` … `golden-en-fleurs-3` | Female/male English: percentage/negation, Indian proper names, technical vocabulary and a sports list | FLEURS `en_us` test split |
| `golden-en-fleurs-1-quiet`, `golden-en-fleurs-1-noise` | Same exact human speech/reference, -20 dB amplitude or 10 dB seeded white-noise SNR | Derived acoustic controls from `en-fleurs-1` |
| `golden-zh-1`, `golden-zh-2` | Mandarin readings from male and female speakers, 10.38/6.84 s | FLEURS `cmn_hans_cn` test split |
| `golden-nl-1`, `golden-nl-2` | Dutch, two distinct utterances, 6.48/9.66 s | FLEURS `nl_nl` test split |
| `golden-de-1`, `golden-de-2` | German, two distinct utterances, 17.94/11.16 s | FLEURS `de_de` test split |
| `golden-zh-en-switch` | 23.475 s, Mandarin → English → Mandarin, different speakers | `zh-1`, `en-1`, `zh-2` joined with 200 ms silence between clips |
| `golden-zh-boundaries` | 37.44 s, pauses, repeated utterances and multiple segments | `zh-1`, `zh-2`, `zh-1`, `zh-2`, with 750 ms silence after each |

The joined files test boundary handling; they are constructed recordings, not
natural bilingual conversations. These are clean read-speech samples, not a
representative noisy microphone or spontaneous-dictation evaluation. The original six LibriSpeech English
clips share a speaker/chapter. The new FLEURS English clips broaden voices and
modern vocabulary; they are still read speech. Quiet/noise variants are controlled
transformations, not natural microphone noise, and are correlated with their source.
Report those controls separately rather than inflating independent corpus size. Dutch and German selections are male recordings.
Keep the existing synthetic Mandarin fixtures for controlled numbers, questions,
and named entities as a complementary test set.

## Attribution and license

All recordings and their dataset references are distributed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
This directory includes the [license text](LICENSE_CC_BY_4_0.txt) for both
original and derived fixture data; the repository's code license does not replace it.

- **LibriSpeech**, Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur:
  [OpenSLR corpus and license](https://www.openslr.org/12). Downloaded from
  [Hugging Face's small validation subset](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy/tree/5be9148/clean),
  revision `5be9148`, `validation-00000-of-00001.parquet`.
  References retain the source `text`, with a trailing newline.
- **FLEURS**, Google and the FLEURS authors:
  [dataset card, authors and license](https://huggingface.co/datasets/google/fleurs),
  revision `4683b04`. Audio comes from `data/<configuration>/audio/test.tar.gz`;
  references are the corresponding normalized transcription column of
  `data/<configuration>/test.tsv`. The manifest includes the utterance ID and
  original audio filename for each selection.

Changes: original clips were decoded and stored as 16 kHz mono PCM16 WAV with
no cropping, loudness normalization, speech removal, or time stretching.
The two explicitly tagged acoustic controls are the exception: quiet multiplies
samples by 0.1; noise adds white Gaussian noise (NumPy PCG64 seed 2468) with
noise power one-tenth of source signal power, scaling the whole result to peak 0.99
only if needed. References remain the source text.
The long English composite stores float32 WAV to preserve the originally decoded
samples used in the paired timing benchmark. Joined files concatenate the exact
source references with spaces and insert the silence described above.
FLEURS clips were selected before model evaluation: 5–20 s, distinct utterance
IDs, the first eligible archive members; Mandarin additionally requires one
speaker of each gender and references without Latin parenthetical translations.

## Reuse

From the repo root, after local Team ID signing and installing the chosen models:

```sh
# Paired parent/current production policy and one golden quality benchmark.
PIPELINE_BENCHMARK_MODEL=multilingual \
PIPELINE_BENCHMARK_FIXTURE=golden-en-boundaries \
PIPELINE_BENCHMARK_ITERATIONS=3 scripts/dev.sh benchmark --release --only asr-quality

PIPELINE_BENCHMARK_MODEL=senseVoice \
PIPELINE_BENCHMARK_FIXTURE=golden-zh-boundaries \
PIPELINE_BENCHMARK_ITERATIONS=3 scripts/dev.sh benchmark --release --only asr-quality

# Quality inventory for all installed, language-compatible local models.
PIPELINE_BENCHMARK_GOLDEN=1 PIPELINE_BENCHMARK_MODEL=all \
PIPELINE_BENCHMARK_ITERATIONS=3 scripts/dev.sh benchmark --release --only asr-quality

# Explicitly install missing models into the app cache before that inventory.
PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1 PIPELINE_BENCHMARK_GOLDEN=1 \
PIPELINE_BENCHMARK_MODEL=all PIPELINE_BENCHMARK_ITERATIONS=3 \
scripts/dev.sh benchmark --release --only asr-quality
```

WER ignores case and punctuation while retaining letters and numbers. Mandarin
and the bilingual composite use CER, ignoring case, width, whitespace,
punctuation and symbols. Number-format differences still count as errors.
References must not be edited to match a model's output. Add new IDs and provenance
for new evidence; keep evaluation fixtures separate from training data. Compare
the same model, fixture, machine, SDK revision and build configuration. The paired
policy benchmark checks mean final error and total processing time against the
parent policy; the broader quality inventory reports errors without arbitrary
universal thresholds. Consult `docs/performance-benchmarking.md` for limitations.

## Cleanup references

`cleanup-golden-manifest.json` contains eleven independently authored synthetic
transcripts and edited references (project-authored test data, not external
recordings). These cover English, German, Dutch and Chinese, factual details,
questions, spoken corrections, known spellings, quoted instructions, apologies
and a 683-word transcript with a checked final paragraph. The Apple context test
derives three distinct invoice batches and numbered paragraphs from that long
input, to check multi-session ordering and preservation without rewarding
accidental duplicate removal. All checked anchors must actually occur in input.

`requiredFacts` separates factual preservation from desired improvements such
as removing superseded wording. `required`/`forbidden`/`question` record cleanup
quality misses; valid contractions and common number/time formats may have
explicit alternatives. References remain independent of model outputs. A safe
original-text fallback is reported as fallback, not successful editing.

```sh
# Apple Intelligence: frozen pre-follow-up decoder comparison, single-use
# prepared sessions, multilingual fixtures, and multi-context-window content.
scripts/dev.sh benchmark --release --only cleanup-quality

# Explicit real provider/model; normal app caches and production services.
PIPELINE_BENCHMARK_CLEANUP_PROVIDER=ollama \
PIPELINE_BENCHMARK_CLEANUP_MODEL=qwen3:4b-instruct \
scripts/dev.sh benchmark --release --only cleanup-quality

PIPELINE_BENCHMARK_CLEANUP_PROVIDER=ollama \
PIPELINE_BENCHMARK_CLEANUP_MODEL=llama3.2:3b \
scripts/dev.sh benchmark --release --only cleanup-quality

PIPELINE_BENCHMARK_CLEANUP_PROVIDER=s1 \
scripts/dev.sh benchmark --release --only cleanup-quality

PIPELINE_BENCHMARK_CLEANUP_PROVIDER=compatible \
PIPELINE_BENCHMARK_CLEANUP_URL=http://127.0.0.1:11434/v1 \
PIPELINE_BENCHMARK_CLEANUP_MODEL=qwen3:4b-instruct \
scripts/dev.sh benchmark --release --only cleanup-quality

# Installed Apple Speech locales only; never downloads assets implicitly.
scripts/dev.sh benchmark --release --only apple-speech-quality
```

Provider benchmarks accept `PIPELINE_BENCHMARK_ITERATIONS` (1–10) and
`PIPELINE_BENCHMARK_FIXTURE`. S1-mini tests its supported English cleanup path and
omits custom-vocabulary cases. Llama3.2 tests English/German; Dutch and Chinese
are outside its card's stated languages. OpenRouter tests require explicit
`PIPELINE_BENCHMARK_CLEANUP_PROVIDER=openrouter`, model, and
`PIPELINE_BENCHMARK_CLEANUP_API_KEY`; they make billable requests. Never commit
keys or benchmark transcripts from private dictation.

`LegacyAppleCleanupBenchmark.swift` freezes the production Apple implementation
at `54a27e9` for future comparisons. It is test-only. The normal app never invokes
that baseline, old tools, old output cap or an experimental decoder. Each Apple
fixture gives the new prepared session at least one second of lead time, per
Apple's docs; that wait is outside request latency. Product recording does not
insert such a delay. Apple Speech compares two fresh sessions using the same
production preset; the first is not a forced OS/model-cache-cold measurement.

Single-run cleanup measurements and two Apple Speech sessions do not establish
p95 latency, population WER or performance across every Mac. Cleanup WER/CER can
penalize valid editing alternatives; consult semantic misses, lost facts and
fallback status alongside it. Detailed results belong in
`docs/model-stack-benchmark-results.md` and its structured evidence file.

Apple Speech asset installation is explicit: set
`PIPELINE_BENCHMARK_DOWNLOAD_MODELS=1` to use the framework's normal asset cache.
A supported locale can still fail asset installation; report that fixture as
unavailable rather than claiming that it passed.

The `cleanup-prompts` group accepts an explicit local
`PIPELINE_BENCHMARK_CLEANUP_PROMPT_PATH` and Ollama model, or
`PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH` for saved outputs. It reuses these
references and the same scorer. Incomplete generation preserves the original,
records `completed=false` and fails the protocol assertion while other cases
continue. Completed candidate outputs can still fail quality. The saved-output
scorer checks the manifest hash to avoid comparing different input revisions.

The `external-asr-quality` group accepts `PIPELINE_BENCHMARK_ASR_URL` for a
loopback OpenAI-compatible speech runtime, `PIPELINE_BENCHMARK_MODEL`, languages
and repeats. It uses the same licensed audio/reference files and WER/CER code,
and does not launch a server or download models. See
[candidate evaluation](../../../docs/model-candidate-evaluation.md) for pinned
recipes and [measured outcomes](../../../docs/model-stack-benchmark-results.md).

## Small candidate screens and resource accounting

The local Whistle collector is `scripts/evaluate_whistle.py`; installation, pinned
assets and measured limitations are in [Whistle evaluation](../../../docs/whistle-evaluation.md).
It skips files beyond the documented 30-second native API limit; it never scores a
truncated prefix against a complete reference. Saved outputs use the existing
`external-asr-quality` scorer, now emitting `ASR_SAVED_RESULT` JSON rows.

`asr-file` also records CPU time across all process threads and cumulative process
peak RSS. These include the XCTest/app harness; they are not isolated model memory
or energy. Use separate model runs for memory comparisons. Start with a small
fixture/model screen and advance only useful candidates. Rejected historical
configurations and their evidence remain documented, without an automatic rerun.
