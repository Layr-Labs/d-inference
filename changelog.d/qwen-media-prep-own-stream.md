### Qwen 3.5-family image preparation no longer queues on the running requests' GPU stream

- An image or video request on Qwen 3.5, 3.6 or 3.8 runs its processor and
  vision tower on a GPU stream of its own. Before, it shared the stream the
  running requests' decode steps use, whose command buffers run in submission
  order, so its tower queued behind their steps and their steps behind the
  tower. In production, Qwen 3.8 27B's media
  preparation for a 1-2K-token image took 183 ms (p50) on an idle M5 Ultra,
  352 ms with one to three running requests and 924 ms with four or more.
- The kernels and inputs are unchanged, so the embeddings and outputs are
  expected to be identical. Other model families keep the shared stream.
- `DARKBLOOM_TTFT_MEDIA_PREP_STREAM=0` (or `false`, `no`, `off`) restores the
  shared stream; it is forwarded to the launchd provider job.
