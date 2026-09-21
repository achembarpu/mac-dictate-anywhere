# Dictate Anywhere 2.12.0 (build 42)

## Scope

Separate ordinary AssemblyAI prose from enumerated insertion output, retain raw recognition text alongside the final history entry, and expose raw-text viewing, copying, and search. Existing history remains decodable. Continued sessions do not mislabel a previously polished prefix as a complete raw transcript.

## Verification

- 467 tests discovered: 453 applicable tests passed across the full run and one focused rerun; 14 optional model/benchmark tests skipped.
- The full run passed 452 tests and safely aborted one Chromium numbered-list fixture when its window lost focus. That exact fixture passed on rerun.
- Live AssemblyAI tests used generated audio and isolated native/Chromium editors. They covered the rotation-snapping explanation, mid-sentence insertion, inline enumeration, compound list items, bullet lists, numbered lists, and plain-text renumbering.
- Regression checks cover malformed prose item arrays, paragraph/explicit-list preservation, line punctuation, raw-text persistence/search/deletion, old history decoding, and raw text captured before cleanup.
- Synthetic Escape test events now set their modifier flags explicitly so physical keyboard state cannot change the test input.
- Test logs: `/tmp/dictate-prose-verified.log` and `/tmp/dictate-prose-numbered-recheck.log`.
- This validates generated-audio editor flows, not every real microphone, Intel Mac, or minimum macOS version. Model wording remains probabilistic.

## Release artifacts

- Canonical `./scripts/release-macos.sh` completed successfully; signed Release archive includes both `x86_64` and `arm64`.
- Apple accepted app and DMG notarization. Both stapled tickets validate; deep strict app signature verification and mounted-DMG Gatekeeper assessment pass.
- The Sparkle ZIP and all five deltas have valid Ed25519 signatures checked directly against the public key embedded in the app.
- The 41-to-42 delta reconstructs the full 2.12.0 app with matching file hashes, permissions, and symlink targets; the reconstructed app passes signature, staple, and Gatekeeper checks.
- Appcast version/build are 2.12.0/42. Only the notarized DMG, ZIP, and five referenced deltas are publication assets; no PKG is included.
- Packaging log: `/tmp/dictate-212-release.log`. SHA-256 asset manifest: `/tmp/dictate-212-manifest.json`.
- Publishing the update feed is gated on public downloads matching this manifest.
