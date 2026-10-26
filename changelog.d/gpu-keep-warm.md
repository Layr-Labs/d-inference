### Opt-in GPU keep-warm for time to first token

- `DARKBLOOM_TTFT_GPU_WAKE_ON_ACCEPT=1` submits one trivial GPU command when an accepted request finds the Mac idle, so the GPU wakes while the prompt is rendered and tokenized.
- `DARKBLOOM_TTFT_GPU_IDLE_HEARTBEAT=1` submits one every 1.5 seconds while a model is loaded and the Mac has been idle for 2 seconds, for at most 10 minutes after the last accepted request.
- Both are off by default and skip while any request or device activity is running. `darkbloom start` forwards them to the provider job.
