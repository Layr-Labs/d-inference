### Nemotron 3.5 Super: image and video answers that repeat are stopped

- Super's image and video requests now take the same loop guard as its text requests: an answer that repeats one
  block verbatim (after 4,096 tokens) ends as `length` instead of running to its output cap. Before, such an answer
  could run for up to 131,072 tokens and keep the Mac's media slot for the whole time, so other image and video
  requests to that Mac were refused meanwhile.
- The guard's way out of a repeating thought stays text-only, so a stopped media answer ends as `length`.
- `DARKBLOOM_LOOP_GUARD` governs it as for every other guarded request (`off` turns the guard off).
