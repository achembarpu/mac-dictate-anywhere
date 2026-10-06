# Model runtime policy

The selected speech model is pinned for each recording. Provisional text is for
feedback; a successful final result owns the transcript even when it is shorter
than the preview. Empty or failed finalization preserves the preview fallback.
Decoder and processor choices are automatic, separate from model selection.

## Speech decoding

| Model | Recording and finalization policy |
| --- | --- |
| Parakeet v3, Ultra and TDT-CTC 110M | Fresh SDK overlap session per recording, reused loaded weights; 11-second center with 2 seconds of left/right context. SDK token timings merge the result and finalization flushes the tail. |
| Parakeet v2 | Bounded previews followed by one authoritative whole-recording SDK batch decode. Vocabulary mode applies matching against that final decode's timings and original audio. |
| SenseVoice | Silero pause boundaries target 15-second segments and cap them at 30 seconds. Preserve all captured samples, quiet gaps and the final short tail. Use automatic language detection and normalized text. Recovery uses the same segmentation. |
| Parakeet EOU and English Nemotron | Native streaming sessions use the selected latency tier and native finish output. |
| Multilingual Nemotron | Full-vocabulary 1120 ms native streaming with the selected language. |
| Apple Speech | Progressive transcription, compatible audio conversion, installed locale and contextual vocabulary; finalize through the last audio sample. |
| AssemblyAI | The final Dictation API request owns the result. Preserve language, key terms, context and formatting instructions; connection preparation must not gate Stop. |

Batch preview eligibility requires 500 ms of new audio until text first appears,
then one second. TDT preview input is capped at 15 seconds. Timestamp-based
splicing preserves the earlier provisional prefix and repeated words; it never
determines final text. Capture awaits inference serially so stale previews do not
form a queue.

Each batch recording has independent Silero state. The volume gate qualifies
normal speech; VAD can additionally qualify quiet speech. Recent eligibility
expires after 500 ms, while final eligibility remembers any speech in the
recording. A partial VAD block is padded only for classification; recognition
receives the original samples without amplification or silence trimming.
Cancellation joins an in-flight iteration before clearing buffers.

CTC vocabulary matching is offered for TDT batch models. It decodes the complete
recording once, then applies the SDK's matching session to the corresponding
timings/audio. The unboosted overlap session is cancelled before that pass.
Native streaming finalization does not use this CTC vocabulary path.

## Architecture and preparation

Architecture checks describe the running process slice. An x86_64 process under
Rosetta uses Intel-compatible paths even on an Apple Silicon machine.

| Component | arm64 process | x86_64 process |
| --- | --- | --- |
| Parakeet and English Nemotron | Core ML CPU/Neural Engine defaults | SDK CPU fallback |
| Multilingual Nemotron | Int8 encoder, CPU/Neural Engine | Unavailable; the SDK requires arm64 |
| SenseVoice | Int8 encoder, CPU/Neural Engine | FP32 encoder with Core ML `.all` |
| Silero VAD | CPU/Neural Engine | CPU |
| CTC vocabulary | Core ML CPU/Neural Engine defaults | SDK CPU fallback |
| S1-mini | llama.cpp Q4_K_M with Metal | llama.cpp Q4_K_M on CPU |

Core ML settings permit processors; they do not guarantee placement of every
operation. Apple Speech, Apple Intelligence and remote services manage their own
execution. The app exposes no processor calibration or decoder tuning workflow.

**Prepare models ahead of time** controls automatic loading and first inference.
Batch preparation decodes synthetic silence and warms VAD; native English
streaming managers process/finish silence and reset. Vocabulary preparation also
warms its CTC models. Synthetic output is discarded. Repeated preparation reuses
resident weights, and each real recording starts with fresh decoder/VAD state.
A vocabulary option enabled during recording can load lazily for finalization
without adding synthetic warmup at Stop.

Startup prepares the selected speech and eligible cleanup models. Model,
language, download and preparation-setting changes request preparation while
idle. Concurrent requests join one operation; a changed selection queues after
an existing load. Cloud dictation and non-English S1 selections skip unused
cleanup preparation. During recording, capture starts before cleanup preparation
is overlapped with speech. Shutdown joins preparation before unloading.
Disabling automatic preparation defers loading until use; it does not unload
already resident models.

Settings distinguish **Downloaded**, **Preparing for first use…** and **Ready**.
Downloaded files alone do not establish readiness. Preparation moves loading and
initial inference out of first use; it does not remove microphone setup, actual
recognition or new dynamic-shape compilation.

## Cleanup contracts

The shared planner preserves source characters, separators and order. It prefers
sentence/paragraph boundaries, recognizes CJK punctuation and rejects oversized
unbroken identifiers instead of splitting them. Providers without tokenizers use
conservative UTF-8 byte budgets. Failed cleanup preserves the whole original;
malformed individual responses retain that chunk's input. These safeguards do
not establish arbitrary semantic fidelity.

Apple Intelligence cleanup runs with or without captured writing context.
Apple Intelligence, Ollama, OpenRouter and OpenAI-compatible cleanup show editable
default prompts. On launch, missing or whitespace-only saved prompts are filled
with the provider's default and persisted; existing custom prompts are preserved.
Each editor offers Reset to Default, which also saves the restored prompt.
Apple's empty-input safeguard uses the same default during preparation and
processing if the field is cleared while the app is running.

| Provider | Request and preparation policy |
| --- | --- |
| S1-mini | English-only trained control prompt, empty thinking prefix and greedy sampling. Q4_K_M weights and a 4,096-token context. Metal uses FP16 KV; Intel uses Q8 KV and up to eight physical cores. Tokenizer-aware chunks stay within 1,000 input tokens; output budget is `ceil(inputTokens * 1.3) + 32`. EOS is required; an incomplete response cannot replace the original. |
| Apple Intelligence | Greedy guided action/text output, fresh sessions and a single-use prepared prefix. Context planning reserves instruction/schema/output space and limits each input to 1,024 tokens. Source paragraphs over 1,024 UTF-8 bytes use independent sessions; lost numeric literals/counts preserve the passage. |
| Ollama | Inspect `/api/show` capabilities, preserve server sampling/reasoning defaults and use strict structured output. Working context is bounded to 8,192 tokens or the smaller model limit. Explicit non-thinking capabilities permit an input-derived output ceiling; unknown/thinking models retain natural EOS. Empty generation preloads the same model/context for ten minutes. |
| OpenRouter | Catalog capabilities supply context/output limits and supported parameters. Preserve declared sampling/reasoning defaults; schema requests require schema-capable routing. Preparation refreshes catalog/connection without a billable completion. |
| OpenAI-compatible | Preserve server defaults and request a strict schema. Adapt only to explicit unsupported-parameter errors; model names alone do not prove capabilities. Preparation discovers models/opens the connection. |

Chat providers reject reported truncation, filtering, refusal and tool-only
responses. Missing optional completion metadata cannot provide the same assurance.
Broken JSON envelopes are never pasted. Literal dictated apologies are valid;
newly introduced refusal language is rejected. Apple preparation is invalidated
when its prompt, vocabulary or context changes, including cancellation of an
in-flight preparation. The app does not add a delay at Stop to wait for prewarm.

S1 preparation exercises tokenization and generation with synthetic input. Its
actor retains context allocations but clears KV data/token positions after each
successful request. Cancellation/decode errors discard the context; unloading or
model replacement frees it before the weights. Requests share no transcript
history.

## Development references

FluidAudio is pinned to 0.17.5. The SDK logger emits warnings/errors without console
mirroring; `DICTATE_ANYWHERE_KEEP_FLUID_DEBUG_LOGS=1` enables speech debug logs in
Debug builds only. See the [tracing map](performance-tracing.md) and
[benchmark guide](performance-benchmarking.md) for diagnostics and reproducible
checks. Golden references, hashes and licenses remain with the test fixtures.

Policy sources: [FluidAudio overlap configuration](https://github.com/FluidInference/FluidAudio/tree/v0.17.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow),
[SenseVoice](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/SenseVoice.md),
[multilingual Nemotron](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/NemotronMultilingual.md),
[S1 author recipe](https://huggingface.co/superwhisper/s1-mini).

S1 preserves the original when cleanup removes a numeric minus sign, including
repeated occurrences, or when literal chat markers could become prompt controls.

Multilingual v3/Ultra sessions capture the selected language at recording start
and pass the SDK script hint through previews, final windows and vocabulary
decoding. Recovery files use the requested language for the whole file. This
filters alphabet confusion; it does not constrain vocabulary within a script.
Languages absent from the SDK mapping retain automatic decoding.
