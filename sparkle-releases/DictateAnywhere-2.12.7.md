# Dictate Anywhere 2.12.7

This update makes permission and dictation setup easier to understand and resolve.

- One setup banner lets you browse microphone, Accessibility, speech-model, and transcript-cleanup issues, with actions that take you to the right setting.
- Permission checks refresh when the app starts, when you return to it, and when dictation or pasting needs access.
- On-device Apple Speech no longer asks for an unnecessary separate Speech Recognition permission.
- If System Events access is declined, keyboard paste remains available and the setup banner offers an optional recovery action.
- Cancelling or quitting during failed microphone startup no longer reopens the processing overlay.
- Resolved setup warnings can appear again when a new issue occurs, including changes to the AssemblyAI API key.

Thanks to @achembarpu for contributing this update.
