# Dictate Anywhere 2.11.0 release validation

September 17, 2026. Candidate: **2.11.0, build 41**. Baseline: `239b066` / v2.10.0.

The initial assessment identified three defects despite the existing suite passing. All three have been fixed and covered by regression tests. Public release packaging and verification are recorded below.

## Fixes

### Cancelled recording retention

AssemblyAI keeps temporary audio for cloud failure recovery. Intentional cancellation now separately respects the preservation choice captured at session start. Turning the setting off deletes the cancelled capture; changing the setting during recording applies to the next session. Explicit continuation retains its existing semantics.

Tests exercise the actual AppState cancellation path with preservation off, on, and changed mid-session. A separate provider-failure test verifies that cloud error recovery still retains audio when cancellation preservation is disabled.

### Editable prompt controls

Shared-context requests now include applicable style, destination, cleanup, additional, mid-sentence, and search preferences. Each active preference gets part of the bounded instruction budget, so one long prompt cannot suppress later controls. Protected insertion rules and complete JSON context remain intact. The UI explains that long preferences may be shortened.

Default Formal and Original tone instructions now describe tone without requiring standalone sentences or preventing contextual layout. Mid-sentence instructions are not applied at list-item starts. Live testing caught and resolved enumeration regressions while integrating these preferences; earlier failed attempts are not counted as release verification.

### Plain-text numbered lists

Multiple inserted items now trigger a bounded replacement that adjusts following sequential ordinals. Nested content, existing line endings, and unrelated sections are preserved. The app verifies the live text against the retained cursor snapshot, verifies the editor's selection update before pasting, and restores the caret after the inserted items when the final text matches.

Native rich lists continue to let the editor maintain its own numbering. When live text cannot be verified or the editor cannot update its selection, dictation stays on the clipboard. Local renumbering is bounded to fields of at most 100,000 UTF-16 code units and follows contiguous ordinal sequences; it does not repair pre-existing irregular numbering.

Unit tests cover nested lists, indented lists, CRLF, Unicode offsets, following unrelated text, stale snapshots, selections, and rich-list exclusion. A live Chromium textarea test verifies the real paste changes following items from 4/5 to 5/6.

### Publication order

RELEASE.md now requires publishing and verifying release assets before pushing the appcast on main, avoiding an update feed that points to unavailable downloads.

## Final test evidence

- Complete XCTest run: **458 total, 444 executed, 14 skipped, zero failures**.
- Included all **13 Chromium live fixtures** and the native editor/API fixture test (three scenarios), with real AssemblyAI requests and generated audio.
- Verified single words, multiword and longer phrases, sentence insertion, inline enumeration, bullet and numbered enumeration, compound names, action lists, neighboring terminal periods, and plain-text renumbering.
- Passed cancellation, failure-recovery, prompt override/budget, and numbering safety regressions.
- `git diff --check` and canonical packaging script syntax checks passed.
- Full log: `/tmp/dictate-211-full-validation.log`.
- Result bundle: `/tmp/DictateInsertionLive/Logs/Test/Test-Dictate Anywhere-2026.09.17_17-26-49--0400.xcresult`.

The 14 skipped tests require separate local-model downloads, real-ASR fixtures, or opt-in benchmarks. Tests ran on Apple Silicon/macOS 27.0. They do not establish Intel/minimum-macOS runtime behavior or direct Codex editor behavior; Chromium fixtures were isolated from the user's browser profile. Real microphone/hardware behavior was not re-tested in this release run. Model-driven formatting remains probabilistic beyond the exercised cases.

## Artifact and publication verification

Packaging uses `./scripts/release-macos.sh`; the DMG is the primary public artifact. No release may be published unless DMG notarization, stapling, and validation succeed. The Sparkle ZIP, signatures, deltas, universal architectures, public downloads, and appcast must also be verified.

- Canonical release script completed successfully; log: `/tmp/dictate-211-release.log`.
- Universal Release app verified as `x86_64 arm64`, version 2.11.0/build 41.
- App and DMG notarization accepted by Apple. Both staples validated.
- Mounted DMG app passed deep/strict signature verification and Gatekeeper as Notarized Developer ID. DMG filesystem checksum validation passed.
- Sparkle ZIP and all five deltas passed independent Ed25519 signature and length verification against the app's public key. That key matches 2.10.0.
- Applied the 40-to-41 delta to the actual 2.10.0 release. All 68 regular files match the full 2.11.0 ZIP byte-for-byte; the reconstructed app passed signature verification, Gatekeeper, and staple validation.
- Appcast XML passed validation and references 2.11.0/build 41 with the expected five signed deltas. Retained older release URLs remain on their original versions.

Publication target: https://github.com/hoomanaskari/mac-dictate-anywhere/releases/tag/v2.11.0. Assets must be publicly verified before exposing the appcast on main.


Artifact SHA-256:

- `DictateAnywhere-2.11.0.dmg`: `7b2724b529163414a7831b4192cf8cabf6dd903cd5cecd94c664decdba0631c9`
- `DictateAnywhere-2.11.0.zip`: `9a9e54003ba148b8973bb8f1fb84bbbf3dbcb207665cc03b250f421eb8b1ce8d`
