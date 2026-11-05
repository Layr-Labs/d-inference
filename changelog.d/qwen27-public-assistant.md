### Qwen3.8-27B pairs decode with their speculative assistant through Darkbloom

- Two-Mac pairs that serve Qwen3.8-27B in tensor parallel through Darkbloom
  now decode with the model's speculative assistant (depth 3), as local
  clusters and single Macs already do. The guided setup plans it under the
  default `mtp_mode = "auto"`. `mtp_mode = "off"` still plans the pair
  without it.
- On one pair, the same requests decoded with the assistant and without it
  gave identical greedy, sampled and tool answers. Requests that ask for
  logprobs, use penalties or a logit bias, or carry images decode one token a
  step, as before. The evidence is in
  `docs/reports/2026-11-05-qwen27-public-assistant.md`.
- The release's cluster runtime facts name the assistant: the model's
  tensor-parallel qualifications rest on that report, and its resource policy
  digest carries the assistant's exact settings. A pair whose Macs run another
  assistant is refused before any part stops.
- Speed records from served requests now say whether the request came through
  Darkbloom or the local API and whether the assistant decoded it. A plan uses
  only the records served the way it will serve, so a local pair's assisted
  speed no longer stands for the same pair through Darkbloom.
