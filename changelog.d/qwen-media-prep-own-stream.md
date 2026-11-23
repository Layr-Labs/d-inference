### Opt-in: Qwen 3.5-family image preparation on its own GPU stream

- New opt-in `DARKBLOOM_TTFT_MEDIA_PREP_STREAM=1` (or `true`, `on`, `yes`;
  off by default). An image or video request on Qwen 3.5, 3.6 or 3.8 then
  runs its processor and vision tower on a GPU stream of its own. By default
  it shares the stream the running requests' decode steps use, whose command
  buffers run in submission order, so its tower queues behind their steps and
  their steps behind the tower.
- The kernels and inputs are unchanged, so the embeddings and outputs are
  expected to be identical. In this change's hardware run, one start with the
  option on gave a different answer for its first images after a cold start,
  which is not yet explained; the option stays off by default until first-use
  identity after a cold start is proven on hardware. Other model families
  always keep the shared stream.
- The setting is forwarded to the launchd provider job.
