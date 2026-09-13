# Isolated benchmark cache root and key mode

> Last updated: 2026-09-05 · commit `3aa73029e`

The standalone wrapper now activates its isolated cache root and explicitly
selects the requested key mode, then checks the actual reported mode. The SPI
retains actionable cache-construction status before shutdown. Production cache,
model eligibility and native attention gates are unchanged.

## Failure and correction

The first exact Qwen3.6 paged SSD smoke failed before serving requests with
`ssdUnavailable`. The matching cache-off smoke passed. The wrapper had supplied
`DARKBLOOM_PREFIX_CACHE_TEST_ROOT` without the affirmative
`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` required to honor that path.
Its executable argument allowed an ephemeral key but did not select one.

Read-only inspection found an empty namespace under the normal cache root with
mtime inside the failed run, while the requested root was absent. Source ordering
creates the namespace before loading key material. This strongly implicates the
unsigned persistent-key path, but the original generic error does not expose the
underlying thrown key error. The earlier inference of a native/store eligibility
refusal from the absent requested root is withdrawn. Exact metadata proves the
target embedding is affine with BF16 scales/biases; only the MTP head is MXFP8.
Prompt artifacts, reconstructed v3 identity, binary and bound metallib also match.
No key contents were read and no host namespace, key or configuration was repaired
or removed.

The wrapper sets the owned root, `ALLOW_EPHEMERAL=1` and explicit
`TEST_PERSISTENT_KEY=0` for ephemeral or `1` for persistent/default mode together.
Inherited flags cannot change that choice. The existing persistent-key acceptance
guard remains, and current SSD reports must have the requested actual key mode.
A completed child followed by failed report validation is classified as failed.
The narrow historical implicit-schema-1 compatibility exception remains.

`EngineV2BenchmarkSession.Failure.ssdUnavailable` now carries the exact
pre-shutdown `PrefixCacheModelStatus` and whether the evidence source exists.
Shutdown, assistant release and the eligibility guard retain their behavior.

## Validation and limits

All **42 Python test functions** pass locally and under M5 Python3.9.6. New tests
exercise the actual main-to-child environment under conflicting inherited flags
and refuse wrong or missing observed key modes. One initial test expectation
failed on `/var` versus resolved `/private/var`; its test-only correction and
original failure are retained.

The diagnostic-only probe release build passes in 248.02 seconds. Root verified
34 build payloads, 677 provider inputs, the single SPI source delta, actual
compiler paths and the separately retained binary hash. The pre-existing
compile-only package dependency path substitution is explicitly verified. Native
and dependency source lineage remains the accepted build's 480 and 1,356 inputs,
plus 27 Jinja inputs. The diagnostic probe was not used for a model run in this
record. The corrected SSD attempt uses the original compiled engine so the
wrapper correction can be isolated; its results belong to a later record.

The [manifest](evidence/isolated-cache-key-mode-2026-09-05/manifest.json) and
[archive](evidence/isolated-cache-key-mode-2026-09-05/payloads.tar.gz) retain
95 payloads covering source, build, failed model attempt, identity/native
metadata audits and independent reviews. Binaries are excluded.
Manifest SHA-256: `4e8d6e680550d455897f40c903d901d3afbdcb6106d81b19bf0a445d7f5c5027`.
Archive SHA-256: `eb9cda05c66e34963873cc70db39f3711409aff348404940f8a5ea21a3b9c633`.

This milestone does not establish an SSD speedup, persistent restart, default
promotion or release completion. See the [benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation)
and [production-grant build](2026-09-05-production-grant-harness.md).
