# Model stack defaults

This follow-up extends the FluidAudio/S1 defaults and golden speech tests with
Apple and remote cleanup reliability. Choices stay internal; no hardware tuning
controls are added. Measurements describe the tested Mac, not every possible
device/model combination.

## Cleanup response integrity

All OpenAI-compatible cleanup paths reject responses reported as incomplete,
filtered, refused or tool-only. Ollama likewise rejects unfinished generation.
Servers omitting optional completion metadata remain supported, but broken JSON
envelopes are never pasted as transcript text. Strict schemas reject unknown
properties. Errors leave the original complete transcript available to AppState.

The shared chunk planner preserves input characters and separators, uses
backend-specific context tests, and prefers sentence/paragraph boundaries. It
also supports Chinese punctuation without adding spaces. Unbroken identifiers
that cannot fit fail rather than being split into different identifiers.

Verification: Team-signed Debug suite, application Swift warnings-as-errors:
605 tests, 545 passed, 60 opt-in skips, zero failures. Response contract tests
cover truncation, refusal, absent metadata and content parts. Planner tests cover
lossless multilingual partitioning, cancellation and oversized identifiers.

Sources:

- [OpenRouter structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs)
- [Ollama generate response contract](https://docs.ollama.com/api/generate)
- [Apple context budgeting](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
