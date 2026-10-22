### Qwen MTP decode without seed steps

- Qwen 3.5, 3.6 and 3.8 requests with the inline MTP head decode as ordinary chained steps while more than one request is decoding, because the head speculates for one decode row only. These steps previously ran unchained, each with a vocabulary-wide policy top-two reduction and an extra host readback. The head's history is still fed from every committed position, so speculation resumes without a seed step when one request remains.
- The final prompt position seeds the first speculative round, so speculation starts right after the first token instead of after one extra target-only step.
- Rollback: `DARKBLOOM_TTFT_QWEN_MTP_CHAINED=0` restores the seed steps and `DARKBLOOM_TTFT_QWEN_MTP_CARRY=0` restores the post-first-token seed step, in processes that receive them (LaunchAgents do not forward them).
