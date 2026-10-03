# Choosing speech and cleanup models

On **Speech Model**, choose your expected language first. The model menu shows
compatible choices for that language and this Mac, grouped into recommendations
and alternatives. Names identify the actual checkpoint; the purpose beside each
name describes when to try it. Download sizes and limited coverage are visible
before choosing a model. Selecting a language does not select or download a
model for you.

| Speech choice | Underlying model | When to choose it |
| --- | --- | --- |
| Parakeet v3 | NVIDIA Parakeet TDT 0.6B v3 | Balanced dictation across 25 European languages. |
| Parakeet v2 | NVIDIA Parakeet TDT 0.6B v2 | English final accuracy. |
| Parakeet 110M | NVIDIA Parakeet TDT-CTC 110M | A smaller English download and memory footprint. |
| Parakeet EOU 120M | NVIDIA Parakeet Realtime EOU 120M | Compact live English preview and optional hands-free automatic stop. |
| SenseVoice Small | FunAudioLLM SenseVoiceSmall | Mandarin with mixed English and Simplified Chinese output. |
| Nemotron 3.5 0.6B | NVIDIA Nemotron 3.5 ASR Streaming 0.6B | Multilingual live preview on Apple Silicon; coverage varies by language. |
| Parakeet Ultra | moondream Parakeet Ultra | An alternative multilingual checkpoint; compare it with v3 on your own speech. |
| Nemotron EN 0.6B | NVIDIA Nemotron Speech Streaming EN 0.6B | An English streaming alternative with configurable buffer presets. |

English Nemotron appears once in the catalog. Its **Streaming preset** chooses
560, 1120 or 2240 ms audio buffers. Smaller buffers provide earlier previews;
larger buffers delay previews and improve processing throughput. Each preset has
its own download. Existing preset selections and downloaded files remain usable.
Buffer size alone does not establish which preset is most accurate.

Parakeet v3 and Ultra include Maltese; they do not support Norwegian. The existing
Nemotron multilingual export supplies the Norwegian option on Apple Silicon.
Greek, Lithuanian, Latvian and Slovenian Nemotron presets have limited coverage;
v3 is recommended for everyday dictation in those languages. The menu describes
the app's current export presets, rather than promising every upstream locale.
SenseVoice's app choices are Mandarin and English. Expected language is a hint
for multilingual recognition, not a translation target.

Your expected language stays selected across model changes. If a saved pairing
is unsupported, settings explain the mismatch and recording asks you to resolve
it before loading the model or starting the microphone. Download size is shown
separately from model identity and is not an estimate of runtime memory.

**Apple Speech** uses macOS-managed language models. **AssemblyAI Dictation** uses
the provider-managed cloud model; its checkpoint version is not pinned by this
app. Their language and availability controls are separate from the local catalog.

On **Transcript Cleanup**, the menu separates built-in local models, vocabulary
correction and custom providers. **Off** retains the speech result after any
enabled local filler removal. **S1-mini** is Superwhisper's English Qwen3 0.6B
fine-tune. **Apple Intelligence** uses macOS-managed Foundation Models.
**Vocabulary correction only** corrects recognition without a cleanup LLM;
availability follows the speech model. Ollama, OpenRouter and OpenAI-compatible
are providers: the visible **Model ID** identifies the model you configured.
The provider/server determines where cleanup runs. S1-mini prefers its pinned
native MLX package on Apple Silicon; retained GGUF installations use llama.cpp
Metal. Intel or Rosetta uses the pinned GGUF package on CPU. See the
[native runtime guide](s1-native-runtime.md) for package selection.

See the [runtime policy](model-aware-transcription.md) for preparation and
finalization behavior, and the [benchmark guide](performance-benchmarking.md)
for comparisons on your hardware and recordings.
