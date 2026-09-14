# Dictate Anywhere 2.10.0

## More reliable shutdown

- Fixed a crash that could occur when quitting after using S1-mini local transcript cleanup.
- The app now stops dictation and releases the local cleanup model before exiting, including when an update requests a relaunch.
- Prevented pending recording startup and saved-session continuation from restarting the microphone while the app is quitting.
- Prevented unfinished transcription work from delivering a late result during shutdown.

Thanks to @achembarpu for the shutdown fixes and regression tests.
