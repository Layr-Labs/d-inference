# Connected Qwen3.8 HTTP coverage and missing SSD publication

> Last updated: 2026-09-05 · commit `c56e9b11a`

Qwen3.8 passes all ten connected coordinator/provider cases with caching
disabled on the rebuilt CLI. Its SSD companion completes the cold donor but
fails the required donation-publication assertion. The paired comparison fails;
this is not an accepted cache-routing or migration performance result.

The cache-off cases cover donor, repeat, tenant isolation, continuation, the
original prompt after continuation, tools, cold vision, cancellation, recovery,
and an unavailable prompt sidecar. The tool case returns the required
`record_color({color:blue,count:2})` call with `tool_calls` finish after 89 output
tokens. The previous 64-token tool budget stopped inside the call; revision3
raises only that request's output limit to 512 while retaining the exact tool
oracle, normal reasoning and MTP. The original failure remains in the evidence.

After the SSD donor, provider heartbeat donation outcome `donated` advances
from zero to one. Coordinator `ssd_donations` and `holder_added` stay zero,
and the captured wire contains no `prefix_cache_ready_v2` message, with zero
dropped wire events. The remaining nine SSD cases never run. A stale prefix
cache gauge cannot override the later donation outcome. These observations
locate a missing publication, but do not by themselves identify its source cause.

Both arms use target aggregate
`bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`,
CLI `678f631cf31b2a62413ae0b318bc5317ace6e1f6b5c7440219456c85940bc82e`,
and native `a932d38cee0beca41ca1a0e71c1e867913a65353`. The CLI release build,
six argument/help controls, source identities and unchanged runtime resources
are recorded. Root verified the six-model revision3 input package before
execution; only Qwen3.8 has run here. Prepared inputs for the other five artifacts
are not runtime evidence.

This test uses two real provider processes on one 128 GiB M5 Max, test trust,
an in-memory coordinator store and ephemeral cache keys. It does not establish
independent-machine capacity, attestation or persistent-key restart. Postflight
checks retain matching runtime/model/config hashes and no remaining owned model
processes. The existing testbed removes its state directory during ordinary
close, so provider log/cache-index files are unavailable after this attempt;
the retained HTTP, wire and heartbeat evidence remains authoritative for the
observations above.

The [manifest](evidence/connected-http3-donation-2026-09-05/manifest.json) and
[archive](evidence/connected-http3-donation-2026-09-05/payloads.tar.gz) retain
134 payloads (6154687 bytes): both raw arms, strict failed comparison, staging
proofs, CLI build evidence, revised inputs/helpers and prior tool-budget failure.
Root verified every archived payload. Compiled executable bytes are excluded.
Manifest SHA-256: `a3e1cfdafcefc70ba030d11cdb2bf0d340b377f7a58518a8c5cd78db8a2c713e`.
Archive SHA-256: `e081dc3b5cba4c03f9ee7fdef156e30bb637eb83a949323f1d457b1373a53a41`.

Related: [revision2 inputs](2026-09-05-connected-cache-inputs-revision2.md),
[Qwen3.6 backend output regression](2026-09-05-qwen36-backend-parity-regression.md).
