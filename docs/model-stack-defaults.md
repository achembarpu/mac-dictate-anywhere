# Model stack defaults

This follow-up extends the FluidAudio/S1 policies and golden speech tests with
Apple and remote cleanup reliability. Defaults stay internal. No hardware tuner
or per-token controls are added. Measurements describe the tested Mac and pinned
models, not every possible recording or device/model combination.

## Provider policies

| Path | Default / preparation |
| --- | --- |
| FluidAudio speech | Model-specific decoder/cadence and Core ML policy from `model-aware-transcription.md` and `model-hardware-defaults.md`; actual inference prewarm. |
| AssemblyAI Dictation | Provider-managed Universal-3.5 Pro, 16 kHz mono PCM, bounded vocabulary/context prompts, one dictation request with raw and optional polished text, raw fallback on cleanup error. Connection warmup must not gate Stop. |
| Apple Speech | SpeechAnalyzer / SpeechTranscriber progressive transcription, compatible audio format, installed locale and contextual vocabulary, `prepareToAnalyze`, authoritative finalization through the last sample. Framework controls compute placement and retention. |
| S1-mini | Author prompt, greedy cleanup, Q4_K_M weights, Q8 caches, tokenizer-aware long-input chunks, Metal on Apple silicon / CPU on Intel. Actual inference prewarm. |
| Apple Intelligence | Greedy guided action/text output with proven production prompts, fresh sessions and single-use prepared prefix. Input AND output fit the system context; no arbitrary output-token cap. |
| Ollama | Inspect `/api/show` capabilities, preserve model/server sampling, bounded 8,192-token working context (or smaller model limit), strict output schema. Identified non-thinking models receive an input-derived output ceiling; reasoning/unknown models retain natural EOS. Empty generation preloads the same model/context for ten minutes. |
| OpenRouter | Cached public catalog supplies supported parameters, context and completion limits. Preserve declared sampling/reasoning defaults. Require schema-capable routing when using structured output; JSON mode alone does not establish schema support. Prepare catalog/connection without a billable completion. |
| OpenAI-compatible | Preserve server sampling defaults because model names alone do not establish capabilities. Use strict schema, adapting only explicit unsupported-parameter errors. Discover models/prepare connection; the portable API has no weight-load operation. |

All cleanup providers have separate implementation files. Shared response
validation and context planning stay independent of transport.

Ollama accepts only reasoning values the server reports. Mandatory reasoning
models keep their default and show an explanatory hint rather than a nonworking
Off selector. In particular, the current `qwen3:4b` tag is Thinking-2507;
`qwen3:4b-instruct` is a different model. Its package supplies temperature0.7,
top_p0.8 and top_k20; Thinking supplies0.6/0.95/20. Neither preset is silently
replaced with greedy. Sampling stays server-managed even for packages without
an explicit preset: forcing greedy decoding caused a real Llama long-input
loop. Completion limits reject truncated output instead of pasting a fragment.

## Completeness and preparation

All compatible chat paths reject reported truncation, filtering, refusal and
tool-only responses. Ollama rejects unfinished/length-limited generation.
Missing optional completion metadata remains supported, so such servers cannot
provide the same truncation assurance. Broken JSON envelopes are never pasted.
Strict output requests disallow unknown properties; server enforcement varies. Completion/transport errors preserve
the whole original through AppState; malformed individual responses retain that
chunk's original text. Literal dictated apologies are accepted, newly introduced
refusal phrases are rejected.

The lossless chunk planner keeps input separators and ordering, prefers sentence
and paragraph boundaries, and recognizes Chinese punctuation without inserting
spaces. Oversized unbroken identifiers fail instead of being split. Providers
without a tokenizer use conservative UTF-8 byte budgets, which can split long
input sooner than an actual tokenizer would. Context limits are safety budgets,
not claims of universal optimal chunk size.

Apple uses the system tokenizer on macOS26.4+, with conservative estimates on
older supported releases. Instruction counting is prepared with the session.
Short inputs proven to fit by a conservative byte bound need no token-count
round trips. Longer passages use actual counts, reserve schema/framing/output,
and are bounded to1,024 input tokens per fresh session. No transcript history
carries into another request. Preparation is invalidated by changed prompt,
vocabulary or context. Cancellation invalidates in-flight preparation before a
new session can reuse it.

For input over 1,024 UTF-8 bytes, source paragraphs receive independent sessions.
The context planner still splits an oversized individual paragraph. Combining
adjacent paragraphs caused omissions in the golden probes. If a long passage
loses a numeric literal or its occurrence count, preserve that entire passage
and emit a content-free fallback trace. Common comma thousands formatting is
accepted. This conservative check can retain an otherwise valid digit-to-word
rewrite or a numeric self-correction; it is not a semantic guarantee about all
names, negations or facts. The paired short-input policy remains unchanged.
Long Apple cleanup trades extra session overhead for better preservation; see
the measured results rather than assuming a latency improvement.


Startup/settings preparation and preparation during recording respect the
existing prewarm toggle. Recording starts capture first, then overlaps cleanup
preparation with speech. Cancel stops capture before joining a preload; shutdown
joins preparation and clears unused Apple sessions. Apple describes prewarm as
best-effort background preparation and recommends at least one second of lead
time. The product adds no one-second delay at Stop.

## Verification and limits

The signed Debug suite and real-provider results are recorded separately in
`model-stack-benchmark-results.md`. Application Swift warnings are treated as
errors. Candidate model and external prompt findings are in
`model-candidate-evaluation.md`.

New authored cleanup fixtures test questions, self-correction, vocabulary,
names, amounts, dates, negation, literal apologies, instructions-as-content,
English/German/Chinese/Dutch and complete long endings. Benchmark quality misses
and original-text fallback are reported separately from content-preservation
checks. WER/CER against one cleanup reference can penalize valid stylistic
alternatives; it is evidence, not a universal cleanup-quality score.

Apple's faster plain-text transformation was evaluated and rejected after
multilingual and long-input regressions. Guided output remains the shipping
path. No adapter is trained: Apple's26 toolkit is its final release and is
incompatible with OS27+. Arbitrary cloud models are covered by contract tests;
real billable calls require explicit benchmark credentials. The portable path
can be tested against Ollama's compatible endpoint; this does not establish
performance for LM Studio or every other server.

## Primary sources

- [AssemblyAI Dictation contract](https://www.assemblyai.com/docs/dictation)
- [Apple SpeechTranscriber overview](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Progressive transcription preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset/progressivetranscription)
- [Apple prewarm contract](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:))
- [Response token limit](https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens)
- [Apple context budgeting, TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- [Apple adapter compatibility](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- [Ollama model details / capabilities](https://docs.ollama.com/api-reference/show-model-details)
- [Ollama generation contract](https://docs.ollama.com/api/generate)
- [Ollama thinking controls](https://docs.ollama.com/capabilities/thinking)
- [Ollama preload and retention](https://docs.ollama.com/faq)
- [Ollama structured output](https://docs.ollama.com/capabilities/structured-outputs)
- [Qwen3-4B-Instruct-2507 model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [Qwen3-4B-Thinking-2507 model card](https://huggingface.co/Qwen/Qwen3-4B-Thinking-2507)
- [Llama3.2-3B-Instruct model card](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct)
- [OpenRouter model catalog](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties)
- [OpenRouter structured outputs and routing](https://openrouter.ai/docs/guides/features/structured-outputs)
