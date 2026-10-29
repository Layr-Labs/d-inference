### Responses that save a cache checkpoint finish sooner

- Saving a prefix-cache checkpoint encodes its older attention rows at the default
  `balanced` checkpoint precision. That encoding now prepares its buffers and its
  check once per segment instead of once per row and writes the same bytes. On a
  Gemma 4 26B request that saves a checkpoint, the end of the response arrived
  about 0.7 s sooner (1.7–2.0 s → 1.0–1.2 s on an M3 Ultra), with identical
  output. Requests that save no checkpoint are unchanged.
