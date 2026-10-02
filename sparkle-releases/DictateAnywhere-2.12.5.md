# Dictate Anywhere 2.12.5

This update speeds up the first dictation and local transcript cleanup.

- Preload the selected speech model and eligible English S1-mini cleanup model at startup. You can turn this off in Settings.
- Faster S1-mini cleanup through native token selection.
- Faster text insertion with a cached paste script and checks for clipboard and target-app readiness.
- Fixed Automation entitlement support in signed releases. macOS may ask to allow Dictate Anywhere to control System Events on the first paste; keyboard-event paste remains available if permission is declined.
- Improved coordination of concurrent model preparation and integrity checks.

Thanks to @achembarpu for contributing this update.
