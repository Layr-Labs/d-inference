### Nemotron 3.5 Super: image and video answers that repeat are stopped

- Super's image and video requests now take the same loop guard as its text requests: an eligible answer that repeats
  one block verbatim is stopped once the guard detects the exact token loop (no earlier than 4,096 generated tokens)
  and ends as `length`, instead of running to its output cap. Before, such an answer could run for up to 131,072
  tokens and keep a media slot occupied the whole time, reducing capacity for other image and video requests.
- The guard's way out of a repeating thought stays text-only, so a stopped media answer ends as `length` (inside its
  reasoning: reasoning and no answer content).
- `DARKBLOOM_LOOP_GUARD` governs it as for every other guarded request (`off` turns the guard off).
