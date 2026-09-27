# 0.9.0 final candidate build

> Last updated: 2026-09-07 · commit `dfa72078a`

The versioned candidate builds and passes artifact review on the M5 Max. Both optimized executables are verified, and the CLI reports **0.9.0**. This closes the versioned-build requirement; final model, HTTP and persistent-restart qualification remain separate.

## Result

The complete foreground run finishes in 255 seconds. All 13 owned commands succeed and retire: source-closure tests, native parser checks, Python comparison checks, two canonical SwiftPM release builds, read-only signature/library inspection and CLI version/help. The native build takes 217 seconds and the CLI build 24 seconds. No model runs during this build.

| Evidence | Result |
| --- | --- |
| Fresh CPU checks | 9 source-closure tests, 8 actual native-parser cases and 24 Python comparison/evidence tests pass |
| Source inventory | All 7,478 declared source identities verified before/after compilation and at collection |
| Product sources | 930 reachable native-benchmark sources; 1,006 reachable CLI sources |
| Dependency locks | All 36 dependency revisions per product match, with clean checkouts and unchanged locks |
| Resources | All six non-executable resources equal the earlier tested candidate |
| Artifacts | All eight actual file hashes, sizes and modes match the artifact manifest |
| Collection and ownership | 93 original files verified; all 13 process groups retired; host released |

The CLI's only changed compiled source relative to the prior numerical-test runtime is the provider version constant. The benchmark additionally compiles the explicit strict/record comparison policy in three source files. Product link dependency closures establish this distinction; the complete SwiftPM inventory also contains unused targets. Twelve test-source symlinks are verified through both their declared link identities and their declared target bytes.

The existing 93 framework tests and numerical controls belong to the earlier runtime; they are not reported as rerun here. The new policy records generated-token differences while preserving prompt identity, cache authentication, tenant isolation, cancellation, accounting and cleanup checks. It does not modify production inference or relax numerical tolerances.

## Publication and preserved failures

Signed merge `dfa72078a` incorporates current master `459c6c898` and resolves five documentation conflicts. Provider, native benchmark, dependency pins and coordinator routing sources are unchanged by this merge. Upstream billing/API/store changes are included; a separately rebuilt connected-test binary uses those merged Go sources for forthcoming HTTP qualification.

Attempt 1 stopped at the host-entry guard before commands began. Attempt 2 passed its three CPU steps, then caller heartbeat expiry interrupted compilation with SIGTERM. Both remain recorded as failed attempts. Attempt 3 uses fresh scratch and dedicated foreground supervision; it does not reuse the incomplete build.

Collection initially encountered four local read-only resource files whose extraction mode differed from the original archive. Their bytes were unchanged. Restoring the recorded modes completed verification without modifying the archive or remote artifacts. The source-review helper's initial link-versus-target identity refusal is also preserved; the successful review verifies the links and targets explicitly.

These are development validation artifacts. This build does not establish production Keychain access, persistent restart, packaging or release-wide model acceptance.

## Evidence

The [machine-readable result](evidence/release090-final-build-2026-09-07/evidence.json) records executable identities, review hashes and the complete original collection hash. The [evidence archive](evidence/release090-final-build-2026-09-07/evidence.tar.gz) contains original build records, product graphs/closures, source inventory, CPU and CLI results, runtime review and preserved failure records; its [manifest](evidence/release090-final-build-2026-09-07/manifest.json) identifies each member. Executables and model data are excluded from the published archive.

Related: [acceptance criteria](../design/release-090-acceptance.md), [earlier numerical candidate](2026-09-06-release090-candidate-build.md), [comparison-policy procedure](../developer/test.md).
