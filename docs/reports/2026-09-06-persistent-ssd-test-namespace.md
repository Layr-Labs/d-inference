# Isolated persistent SSD test namespace

> Last updated: 2026-09-06 · commit `d3d525014`

The standalone cache benchmark can now select a separate persistent key hierarchy
and isolated payload root. Source validation passes 23 provider functions and 24
benchmark functions, including the current packet/metadata/logit option combination.
No real Secure Enclave, Keychain, model, signing or two-process restart operation
was performed. Persistent restart acceptance remains open.

The paired UUID/access-group options derive distinct enclave and wrapped-KEK
selectors while retaining the ordinary secure wrapper, storage and entitlement
checks. Invalid context refuses before slot preparation, filesystem mutation or
key access; namespaced persistent failure cannot fall back to an ephemeral key.
Nil selection preserves existing behavior. This is a standalone benchmark seam;
the full provider loop retains its separate default attestation path.

Validation found an actual absent-leaf alias bug: Foundation's whole-path symlink
resolution left an existing ancestor alias unresolved when the leaf did not exist.
The correction resolves the nearest existing ancestor using `lstat`/`realpath`,
requires a directory, then appends the missing suffix. It applies equally to
candidate and protected roots and refuses dangling links, loops and traversal.
Actual Darwin filesystem tests and key-loader spies cover those cases.

| Evidence | Executed scope | Result |
|---|---|---|
| Provider validation4 | Namespace13, key-mode6, four exact in-memory KEK functions; parent `5ac2b5f3`, native `847e320` | 23 functions pass; all eight changed provider files match the final source byte-for-byte |
| Benchmark validation5 | Initial namespace/metadata/logit/idle union on the same older native | 20 functions pass; retained as earlier evidence |
| Final benchmark validation6/7 | Current parent `1be058a6b`, native `dcf39f6`; namespace6, packet4, metadata3, logit3, idle8 | Build passes; 24 functions pass, no skips, exact binary/source/graph identity checked |
| CPU wrapper/evidence suite | Namespace forwarding, mixed refusal before host work, observed key mode, existing strict evidence guards | 63 functions pass |
| Final selector calibration | Actual ordinary/canonical IDs and adversarial lookalikes | 12 functions pass; exactly 24 benchmark functions selected |

The final total is 47 distinct Swift functions, not 67: the older 20 benchmark
functions overlap the final 24. Provider23 is explicitly carried from its actual
older-native execution; it is not relabeled as a new current-native test run.

All failed attempts remain in the archive: listing-parser failure; zero runtime
matches rejected by the nonzero guard; the actual alias regression; a missing
test-only Diagnostics SPI import; and an incorrect packet-suite count split
(`3/1` instead of the actual `2/2`). The last count correction reused the identical
already-built binary after hash and graph checks. No test or cache gate was waived.

The [manifest](evidence/persistent-ssd-test-namespace-2026-09-06/manifest.json) and
[archive](evidence/persistent-ssd-test-namespace-2026-09-06/payloads.tar.gz) retain
289 verified payloads: source patches/maps, prior failures, compiler graphs,
binary/dependency hashes, exact selected IDs and execution logs. Manifest SHA-256
is `57ac655b5b7ea58efb3d01a4859a1717acd31f2b5d799ddf62ef3b75f3df5f7b`;
archive SHA-256 is `ea4dde2abef970ddf6d8f6c842c9155db403c1f26c361ebbf39c10b15476a7cf`.

Build controls are in [build.md](../developer/build.md#prefix-cache-benchmark-executable),
and invocation/acceptance rules are in [test.md](../developer/test.md#isolated-persistent-test-namespace).
These tests establish a concrete isolated path for later authorized persistent
execution. They establish no SSD latency result, model-token parity or release promotion.
