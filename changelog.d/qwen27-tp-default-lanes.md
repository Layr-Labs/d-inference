### Qwen tensor-parallel pairs serve up to 8 requests at once, sized to memory

- `darkbloom cluster` now sets how many requests a Qwen tensor-parallel pair
  serves at once: 8, 6, 4 or 2, the most that both Macs' memory holds now with
  the full load reservation for that many. The pair serves them from its first
  load. Before, it served one at a time: a local pair widened only after a
  burst, through a reload the burst waited for, and a pair serving Darkbloom
  traffic never widened.
- On two idle Macs, Qwen3.8-27B serves 8 at once from 64 GB a Mac without the
  speculative assistant (4 at 48 GB, 2 at 32 or 36 GB), and 8 from 96 GB a Mac
  with it (local clusters only); smaller Macs serve fewer. Two M5 Ultras serve 8 either
  way. When not even 2 fit, the pair serves one request at a time, as before.
- Memory safety is unchanged: both Macs reserve that many requests' full memory
  when the model loads and admit each request alone. A local pair set up
  narrower still widens when requests queue; a pair set up for 8 is never
  reloaded for it.
- Existing setups keep serving one request at a time until they are planned
  again, as after an update. A pair serving Darkbloom traffic keeps its width
  beside its approval; no approval, registration or committed-start digest
  changes.
