# Dictate Anywhere 2.11.0

- Added AssemblyAI cloud dictation with Verbatim and Polished output, shared vocabulary, and customizable formatting instructions.
- Improved insertion into existing sentences: dictated words follow nearby capitalization, spacing, and punctuation.
- Dictated groups of items now follow the surrounding structure, including bullet lists, numbered lists, and inline comma-separated series. Compound names stay together.
- Improved cursor and list context capture in Chromium-based editors.
- Added guarded renumbering of following items in plain-text numbered lists.
- AssemblyAI cancellation now respects the Preserve cancelled sessions setting. Recovery remains available when cloud transcription fails.
- Custom style and field-context prompts apply when surrounding-text sharing is enabled, within the provider instruction limit.

AssemblyAI requires an API key and an internet connection. Sharing surrounding text is optional. Automatic plain-text renumbering requires an editor that exposes readable text and a writable selection through Accessibility; if the text has changed, the dictation is copied for manual insertion.
