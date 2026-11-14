### Fixed

- GPT-OSS: a recipientless commentary preamble (Harmony's short message before a tool call) now reaches `content`, streamed and collected, instead of being dropped. Tool calls are unchanged: a recipient before or after the channel marker stays a call, and incomplete, oversized, non-assistant and body-embedded commentary headers pass as before. On by default; `DARKBLOOM_GPTOSS_COMMENTARY_CONTENT=0` restores the 0.10.12 behavior.
