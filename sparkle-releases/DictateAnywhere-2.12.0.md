# Dictate Anywhere 2.12.0

- Fixed AssemblyAI Polished dictation splitting ordinary sentences into short, separate lines. Prose now uses its own formatting instructions, and unexpected item arrays fall back to the original transcript.
- Preserved contextual formatting for bullet lists, numbered lists, inline series, and mid-sentence insertion. Single insertions between existing lines follow nearby capitalization and punctuation.
- Added expandable raw transcripts to History for new completed dictations, with Copy raw and search across both raw and final text.

Older history entries cannot recover raw transcripts retroactively. Raw text is not shown for continued or recovered sessions when a complete unedited transcript is unavailable. History remains stored locally on your Mac.
