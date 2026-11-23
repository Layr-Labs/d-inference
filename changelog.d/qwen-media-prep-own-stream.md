### Qwen 3.5-family image preparation no longer queues on the running requests' GPU stream

- An image or video request on Qwen 3.5, 3.6 or 3.8 runs its processor and
  vision tower on a GPU stream of its own. Before, it shared the stream the
  running requests' decode steps use, whose command buffers run in submission
  order, so its tower queued behind their steps and their steps behind the
  tower.
- The kernels and inputs are unchanged, so the embeddings and outputs are
  identical; tower-output hashes at first use matched over fresh cold starts
  on M5 Ultra and M5 Max. Other model families keep the shared stream.
- `DARKBLOOM_TTFT_MEDIA_PREP_STREAM=0` (or `false`, `no`, `off`) restores the
  shared stream; it is forwarded to the launchd provider job.
