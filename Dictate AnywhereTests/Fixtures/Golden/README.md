# Human speech golden references

These 15 audio/reference pairs are test resources, also available to
`scripts/dev.sh benchmark`. No speech model generated or corrected the references.
The manifest records language, metric, sample count, pinned source, source IDs,
transformations, and SHA-256 hashes. Ordinary tests validate every pair without
model inference, downloads, microphone access, or cloud calls.

| IDs | Coverage | Source |
| --- | --- | --- |
| `golden-en-1` … `golden-en-6` | Six English readings, 4.8–29.4 s, including proper names | LibriSpeech validation subset, first six records |
| `golden-en-boundaries` | 72.665 s, multiple decoder windows and shifted speech seams | Those six readings joined with 200 ms silence after each |
| `golden-zh-1`, `golden-zh-2` | Mandarin readings from male and female speakers, 10.38/6.84 s | FLEURS `cmn_hans_cn` test split |
| `golden-nl-1`, `golden-nl-2` | Dutch, two distinct utterances, 6.48/9.66 s | FLEURS `nl_nl` test split |
| `golden-de-1`, `golden-de-2` | German, two distinct utterances, 17.94/11.16 s | FLEURS `de_de` test split |
| `golden-zh-en-switch` | 23.475 s, Mandarin → English → Mandarin, different speakers | `zh-1`, `en-1`, `zh-2` joined with 200 ms silence between clips |
| `golden-zh-boundaries` | 37.44 s, pauses, repeated utterances and multiple segments | `zh-1`, `zh-2`, `zh-1`, `zh-2`, with 750 ms silence after each |

The joined files test boundary handling; they are constructed recordings, not
natural bilingual conversations. These are clean read-speech samples, not a
representative noisy microphone or spontaneous-dictation evaluation. The English
clips share a speaker/chapter. Dutch and German selections are male recordings.
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
