### Qwen constraint spans

- Add default-off `DARKBLOOM_CONSTRAINT_SPANS` support for eligible Qwen strict-auto tool requests and JSON reasoning. Ordinary reasoning and content may draft; tool framing/arguments and JSON values remain protected. Text after a completed call may draft again.
- Forward the flag into the installed provider service. Preserve existing grammar admission, masks, engine eligibility and off behavior. No full-model speedup is claimed.
- On by default since 0.10.13 (measured on Qwen 3.8 27B in its ON state); `DARKBLOOM_CONSTRAINT_SPANS=0` restores 0.10.12's constrained decoding.
