### GLM-5.3-Flash keeps decoding while another request prefills

While other requests decode, GLM now runs eight decode-only steps after each 2,048-token prompt chunk of a
long prompt. Before, a decoding request got about one token per chunk (about a second each on an M5 Ultra)
for as long as another request prefilled: 2.8 tok/s beside an 8K prompt and 1.2 to 1.5 tok/s with two
decoders. With the held steps it measured 19.5 and 7.1 to 7.2 tok/s, while the prefilling request's first
token arrived 6 to 20% later. A request served alone is unchanged, and first-token deadline admission prices
the held steps. `DARKBLOOM_GLM_DECODE_STEPS_BETWEEN_CHUNKS` sets 0 to 64 steps; `0` restores the previous
scheduling.
