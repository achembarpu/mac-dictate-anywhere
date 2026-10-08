# Dictate Anywhere 2.12.9

This update improves audio continuity and reduces work around dictation startup and finalization.

- Preserve continuous audio when converting microphone sample rates, including the final audio tail when recording stops.
- Skip on-device Apple Speech preview processing for AssemblyAI when text preview is turned off.
- Prepare saved audio and AssemblyAI requests with fewer intermediate copies.
- Let local final recognition overlap destination-context capture while keeping delivery dependent on the captured context.
- Overlap audio-route settling with finalization so the app can be ready again sooner.
- Release completed AssemblyAI audio from memory while preserving recovery audio for failed requests.

Thanks to @achembarpu for contributing this update.
