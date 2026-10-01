# Model-aware transcription policy

Recording sessions preserve each user's selected model. Audio polling, model
inference windows, provisional text and authoritative final text are separate
concerns. A successful final result wins even when it corrects a longer preview.
Empty/error finals retain the existing preview fallback.

| Model | Production policy |
| --- | --- |
| Parakeet TDT 0.6B v3 | FluidAudio's streaming overlap preset: 11 s center, 2 s left and 2 s right context. Fresh session per recording, reused loaded models. SDK token timing merges and final-window flush own the final result. |
| Parakeet Ultra | Same v3-family overlap path and Neural Engine encoder placement. Opt-in model choice; existing selections and the default stay v3. |
| Parakeet TDT 0.6B v2 | Bounded 15 s previews; authoritative SDK batch finalizer uses the already-retained original recording. Its mel-context and gap-repair path preserves speech lost by the live overlap preset. |
| Parakeet TDT-CTC 110M | Same SDK overlap session, preserving the model's decoder layer count and SDK handling. |
| SenseVoice Small | Streaming Silero VAD identifies pause cuts; merge toward 15 s and cap at 30 s. Keep every captured sample, including quiet gaps and the last short tail. Auto-detect language, retain punctuated inverse-text-normalized output (`textNorm=14`) and existing int8 ANE/fp32 CPU selection. Recovery uses the same segmenter. |
| Parakeet EOU | Keep selected 320 ms native streaming tier and SDK endpoint behavior; use native finish output. |
| Nemotron English | Keep the user's 560/1120/2240 ms tier; use native finish output. |
| Nemotron multilingual | Keep full-vocabulary 1120 ms native streaming and selected language. |
| Apple Speech | Existing progressive transcription already honors final results and analyzer finalization. |
| AssemblyAI | Existing final Dictation API request owns the result; preserve language, key terms, context and formatting instruction fields. |

The pinned SDK's `hypothesisChunkSeconds` is not used to schedule inference, so
the overlap preset alone first emits text after 13 seconds. Batch models therefore
retain separate provisional previews. Until the first nonempty text, eligibility
stays at 500 ms of new audio; later previews require one second of new audio.
TDT provisional input is capped at 15 seconds. A timestamp-based provisional
splice keeps earlier text visible without suppressing repeated words. It never
determines the authoritative final result. Inference is awaited serially in the
capture iteration, so stale preview requests do not form a queue.

The SenseVoice author's sample uses offline FSMN VAD, `max_single_segment_time`
30 s and `merge_length_s` 15 s ([official usage](https://github.com/FunAudioLLM/SenseVoice#usage)).
This app applies those segment limits with the existing FluidAudio streaming
Silero API, avoiding repeated whole-recording VAD passes. SDK defaults retain
750 ms silence and 100 ms padding. VAD classifies boundaries; it does not discard
audio. Cancellation waits for an in-flight iteration before clearing its buffers.

All five batch models reuse Silero for quiet-speech qualification. Each recording
has its own streaming VAD state. The existing volume gate still qualifies normal
speech; VAD can additionally qualify audible speech below that threshold. Recent
speech eligibility expires after 500 ms, while final eligibility remembers any
speech in the recording. The last partial VAD block is zero-padded only for
classification. Recognition receives the original samples, with no amplification
or silence trimming. Native streaming models retain their existing behavior.
The shared Silero model lives in the app's normal FluidAudio cache.

Opt-in vocabulary finalization decodes the full recording once with the SDK
batch decoder, then applies `VocabularyBoostingSession` to its token timings and
the matching original audio. The CTC spotter handles long audio internally.
This avoids v2's overlap seam regression even with vocabulary enabled.
The unboosted overlap session is cancelled before that final pass. V3, Ultra and
110M finalization flushes the overlap tail; v2 intentionally uses one
whole-recording batch final decode. This adds Stop work on long v2 input
while avoiding a measured word-loss regression. Model selection is pinned for
the active recording.

Policy sources: FluidAudio 0.17.5 at `0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7`,
[overlap configuration](https://github.com/FluidInference/FluidAudio/tree/v0.17.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow),
[SenseVoice](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/SenseVoice.md),
[Nemotron](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/Nemotron.md),
[multilingual Nemotron](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/NemotronMultilingual.md).
SDK defaults are implementation evidence, not a guarantee of optimal WER on
every recording. Use the [shared benchmark harness](performance-benchmarking.md)
and committed golden references to evaluate new policies before changing them.

## Dependency and model choices

FluidAudio is pinned exactly to 0.17.5. The update includes bulk tensor-array
operations, iterative vocabulary alignment and supported logger controls.
The app now sets the SDK logger to warnings and errors without console mirroring.
Debug speech logs require `DICTATE_ANYWHERE_KEEP_FLUID_DEBUG_LOGS=1`; production
builds never enable that override. Process stderr is no longer intercepted.

The SDK recommends [Ultra for new integrations](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/ParakeetUltra.md).
Its published corpus results improve on v3, but this small local inventory has
mixed English results and a better German case. Offer it explicitly rather than
forcing a new download or claiming every clip improves. It uses the normal app
model cache and supports the same 25-language and macOS 14 contracts as v3.
Redux and Phonon-2 trade English accuracy or OS compatibility for other benefits;
they are not added here.

[GPU encoder placement](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/EncoderComputePlacement.md)
is an upstream throughput recommendation, not a portable guarantee. Local paired
ANE/GPU tests on all 11 supported goldens matched errors exactly, but GPU was
slower for v3 and substantially slower for Ultra even after first-use compilation.
Keep the SDK Neural Engine placement. The reusable encoder benchmark permits
future hardware-specific reevaluation. Decoder/joint and preprocessing placement
remain the SDK's model-specific defaults.

The app's CTC vocabulary mode is now offered only for TDT batch models. The native
streaming finish paths did not apply it. Multilingual Nemotron has a separate
SDK decode-time bias API with different weights; adding that mode needs its own
rare-name accuracy and false-insertion evaluation.

## S1-mini cleanup

The [author's model card](https://huggingface.co/superwhisper/s1-mini) recommends
the trained control prompt, empty think block, greedy decoding, Q4_K_M weights,
and roughly 1,000-token input chunks. Keep those settings, Metal loading on
Apple Silicon, and the existing 4,096-token context and Q8 KV cache. Short input
uses the existing single request. Long input splits at sentence boundaries where
possible and otherwise at word boundaries using the pinned model's tokenizer.
Every source character is covered; input is never cut in the middle of a word.
An unbroken over-limit word still fails safely rather than being altered.

Use the complete recommended output budget, `ceil(inputTokens * 1.3) + 32`.
The previous additional 1,024-token ceiling truncated a real long-input benchmark.
Exhausting the output budget now raises an error instead of delivering an
unfinished cleanup; the app's existing error path preserves the original text.
Empty or invalid model output still cannot erase meaningful dictation. Chunk
failures discard the partial cleanup result, preserving the whole original text.
Highly repetitive input can keep generating past even the recommended budget;
the service returns the whole original input in that case, never a truncated
prefix. The repetitive invoice fixture checks this safety behavior separately
from a varied long fixture that must perform its final self-correction.

llama.swift 2.10549.0 is already the latest published wrapper tag checked on
2026-10-01. No dependency or weight-quantization change is warranted without
better local accuracy/performance evidence. Installed-model checks cover numbers,
self-corrections, time, dates and all 110 numbered invoices across long-input
boundaries. The shared benchmark measures short, long and over-limit cleanup.

[Verified results and reproducible evidence](model-aware-transcription-results.md)
record the final checks, timing tradeoffs and rejected configurations.
