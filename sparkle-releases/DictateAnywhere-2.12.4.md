# Dictate Anywhere 2.12.4

This maintenance update adds tools to help diagnose dictation delays and validate future performance improvements.

- Added timing diagnostics across recording startup, speech recognition, transcript cleanup, text insertion, cancellation, and recovery.
- Added repeatable developer benchmarks for recognition and processing workloads.
- Performance tracing is off by default in the distributed app. When enabled for troubleshooting, traces contain timings and configuration labels, not audio or transcript content.

Thanks to @achembarpu for contributing this update.
