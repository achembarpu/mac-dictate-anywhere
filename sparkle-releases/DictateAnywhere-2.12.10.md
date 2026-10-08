# Dictate Anywhere 2.12.10

This update reduces repeated speech decoding and improves model-specific dictation and vocabulary handling.

- Skip provisional speech decoding when text preview is hidden, and reduce repeated preview work during longer recordings.
- Use decoding windows and audio chunk sizes suited to each speech model, while preserving final audio and decoder corrections.
- Update custom vocabulary handling, including native vocabulary support for multilingual Nemotron and shared model weights for English Compact.
- Add the optional Parakeet Multilingual Ultra speech model.
- Improve SenseVoice pause segmentation and final-tail handling, and coordinate Stop and Cancel with active recognition work.
- Keep downloaded speech models usable offline without optional speech detection. Existing installations can add it with Download Speech Detection in Speech Model settings.

Thanks to @achembarpu for contributing this update.
