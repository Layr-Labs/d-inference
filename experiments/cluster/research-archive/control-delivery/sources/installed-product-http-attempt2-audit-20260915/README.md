# Installed HTTP attempts 2 and 3: independent retained-record audit

CPU replay passed for the two source-pinned installed-provider smoke requests. No network, native/model execution, producer-code import, or run-input modification occurred.

| Attempt | Reported prompt/output tokens | External first content | Reported-count deadline | Minimum observed free GiB, ranks 0/1 | Samples, ranks 0/1 |
| --- | --- | --- | --- | --- | --- |
| 2, short | 42 / 128 | 1.339245042 s | 10.042 s | 6.679474 / 26.471909 | 55 / 51 |
| 3, medium | 963 / 128 | 2.461908417 s | 10.963 s | 6.259476 / 25.604507 | 58 / 54 |

Each raw stream contains 131 SSE events: role, 128 nonempty content events, length finish with usage, and DONE. No reasoning events occurred. All 218 resource observations independently reconstruct above 6 GiB free, zero reported swap, pressure 1 and AC. These are sampled observations.

Both saved supervisors observed provider exit 0 without forced kill. Saved postflight scans contain no named provider/worker processes and both lease journals are empty; raw interface snapshots support alias restoration. The reviewed installed cleanup contract requires native cleanup, owner release ACK and owner exit 0 before normal CLI success. Individual ACK frames are not retained in these HTTP folders. Hummingbird cancellation/Already closed shutdown diagnostics remain in the original stderr.

Token counts are server-reported; content-delta counts are not independent tokenization. This audit does not compare numerical answers or qualify sustained, representative, long-prompt, OpenRouter or release behavior. Timing is external send-to-content, not engine throughput. HTTP-body EOF and clock sampling are source-bound client observations, not independently attested network/clock captures.

`replay.py` reads only fixed retained inputs and writes a new `replay-results.json` exclusively; preserve the existing result before a replay. `source-review.json` binds the interpretation and copied cleanup sources. `manifest.json` pins this audit package; input hashes are in the replay result.
