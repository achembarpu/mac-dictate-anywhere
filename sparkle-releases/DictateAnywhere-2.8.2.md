# Dictate Anywhere 2.8.2

- The dictation overlay now appears on the display containing the focused text field, even when the pointer is on another monitor.
- Overlay placement remains stable throughout a dictation and is reselected for every new dictation session.
- Rapid consecutive dictations across different displays now dismiss the previous result badge immediately and keep the new listening overlay visible on the correct display.
- Multi-monitor detection now avoids repeated cross-application accessibility lookups during waveform updates and restores the shared accessibility timeout after each lookup.
