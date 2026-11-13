### Fixed

- Added opt-in `DARKBLOOM_GPTOSS_COMMENTARY_CONTENT` for gpt-oss commentary content. Recipientless assistant commentary reaches content before a following tool call, for streamed and collected output. Recipient headers before or after the channel marker remain tool calls. Header tracking is bounded; incomplete, oversized, non-assistant and body-embedded commentary headers are preserved. Default-off behavior is unchanged.
