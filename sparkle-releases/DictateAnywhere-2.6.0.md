# Dictate Anywhere 2.6.0

- Added automatic speech-model and language switching when you change the macOS keyboard input source.
- Added per-keyboard mappings in General settings, so inputs such as ABC and Pinyin can use different transcription engines, models, and languages.
- Mapped models are prepared as soon as the active keyboard source changes, including immediately after you edit its mapping.
- Auto-switching only uses models and Apple Speech language assets already available on your Mac. It never starts a model download without you choosing one.
- Added clear guidance when a mapped model is not downloaded, an Apple Speech language is not installed, or a model is unavailable on the current Mac.
- Preserved vocabulary post-processing when switching away from and back to a compatible transcription model.
