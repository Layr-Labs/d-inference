### Qwen constraint spans

- Add `DARKBLOOM_CONSTRAINT_SPANS` support for eligible Qwen strict-auto tool requests and JSON reasoning, on by default since 0.10.13 for the Qwen 3.8 27B build only (measured there in its ON state; other builds stay off unless set to `1`; `0` restores 0.10.12). Ordinary reasoning and content may draft; tool framing/arguments and JSON values remain protected. Text after a completed call may draft again.
- Forward the flag into the installed provider service. Preserve existing grammar admission, masks, engine eligibility and off behavior. No full-model speedup is claimed.
