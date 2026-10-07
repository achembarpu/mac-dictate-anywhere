# Dictate Anywhere 2.12.8

This update improves dictation privacy, settings reliability, and Mac compatibility.

- Pasting stays tied to the app where dictation started. If that destination closes or cannot regain focus, your transcript remains available to copy.
- OpenRouter keys pasted into the optional environment-variable field move into Keychain. Existing keys in that field are migrated, with a visible error if secure storage fails.
- Settings controls, keyboard navigation, accessibility labels, and error messages are more consistent.
- Provider checks discard outdated results when credentials or models change, and transcript history finishes saving before delivery or shutdown.
- Release packaging verifies Apple silicon and Intel support throughout the app, including bundled updater tools.

Thanks to @achembarpu for the settings and universal-build improvements in #30 and #31.
