# Dictate Anywhere 2.12.11

This update improves transcript cleanup reliability and reduces repeated work across cleanup providers.

- Preserve complete transcripts when cleanup responses are truncated, filtered, malformed, or fail.
- Process long S1-mini transcripts in bounded chunks while preserving source paragraph and line separators.
- Reuse S1-mini inference resources while clearing transcript state between requests, and improve cancellation recovery.
- Improve Apple Intelligence cleanup defaults and long-transcript handling.
- Reduce repeated provider discovery and overlap independent OpenRouter cleanup requests while preserving transcript order.
- Simplify Ollama and OpenRouter reasoning controls. Preserve saved reasoning-Off preferences on older Ollama servers.
- Simplify Ollama setup around installed models; model downloads are managed through Ollama.

Thanks to @achembarpu for contributing this update.
