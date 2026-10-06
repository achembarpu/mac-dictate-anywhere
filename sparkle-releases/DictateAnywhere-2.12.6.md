# Dictate Anywhere 2.12.6

This update reduces recording delays and makes the dictation overlay more efficient.

- Final recognition can start sooner after microphone capture stops. Rapid restarts retain the Core Audio settling gap before the next capture begins.
- More efficient audio metering with a bounded sample buffer and fewer unnecessary display updates.
- Reduced overlay updates and faster long-transcript previews, preserving Unicode character boundaries.
- Same-length live transcript corrections now appear in the preview.
- Saved system output state is restored after successful, empty, failed, or cancelled dictation. The output settling delay applies only when recording actually muted the output.
- Faster transcript normalization and list parsing through cached expressions.
- Added focused performance benchmark groups for development.

Thanks to @achembarpu for contributing this update.
