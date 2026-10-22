# Same-cache private Go driver qualification

This wrapper is source-only and has not prepared, compiled, tested or run anything. It adds an explicit private trust-only mode and reuses the exact actual shared-request Go workspace `cluster-native-shared-request-go-coverage-checks-1-20260917/workspace`, original 1,125-source snapshot `c5e3fae3...e9624`, full-check receipt `ef900efa...708ae` (2,806 passes, three existing skips), and unchanged Go module/sum/toolchain. No cache clone, module download, model operation, remote operation or MAIN edit is performed.

The eight Go paths from frozen driver e0 are overlaid; the enabled command has the narrow `startup-mode.patch` successor, and one new private command test is added. Two existing Registry sources change; the other seven driver/test paths are new to the prior workspace. Building the actual coordinator command additionally needs four unchanged, separately pinned files: main_test.go, maintenance.go, maintenance_test.go and config/app_config.go. Their local imports are already in the qualified closure except the new command/config packages. The exact projected inventory is 1,136 files and 28 packages. `integration.json` lists every write and expected preimage/absence; `projected-source.json` is prospective, not a materialization claim.

`prepare.py` first verifies the actual entire old workspace and all preimages, saves the original source inventory and replaced source bytes, then performs only those thirteen small writes. Known optional old coordinator binaries are preserved and rehashed if present; every new build goes to a fresh wrapper output directory, so old products are never replaced. A failed preparation retains its journal/backups and cannot satisfy the run gate. No automatic rollback or retry is claimed.

Under a future explicit exclusive compiler/materialization grant, run sequentially:

```
python3 -B check_source.py
python3 -B prepare.py
python3 -B run.py --phase check --attempt 1
python3 -B run.py --phase build --attempt 1
```

Use fresh regular outer logs. The exact previously qualified `owned_process.py`, `check_process.py` and `go_coverage.py` are retained. Every compiler/test child has its own group, bounded 300-second parent wait, actual reap/group-absence gate and retained raw receipt; Go is jobs 2, race tests, no automatic downloads, sanitized service credentials. Source pins are checked before and after each child, including failure. Test limits are 120 seconds (focused/command), 180 seconds for optional full batches. No built coordinator is executed by this wrapper.

The mandatory check phase executes six bounded children: default go-list selection, default 51 focused methods, all eight command tests; then private-tag selection, private 54 methods (the previous 32 NativePair + 15 VerifiedPair + four member controls plus the three real observation tests), and all eleven command tests (eight unchanged plus three mode controls). Go-list verifies that hardware observation/API/fixture/entry files are excluded by default and that only the default stub is selected; the private tag reverses that selection. Exact compiled test completions, not source-name counts alone, determine PASS.

The build phase requires that exact check receipt and emits separate default/private coordinator products. It never infers TLS, member attestation, native admission, physical cleanup, or encrypted RDMA qualification from a Go build.

If root chooses broader qualification after a new failure or runtime change, `run.py --phase full --attempt 1` retains the established exhaustive compiled-discovery and four API batches under the private tag. Its catalog must be the actual prior catalog plus exactly the three new methods; all other names and three prior explicit skips are unchanged. It covers the affected full Registry/protocol/API suites, not unrelated coordinator packages or benchmarks. This optional repeat is not automatically required merely because the old full suite exists; the mandatory targeted race and command/default controls address this driver and startup-mode change.

The private coordinator config is now `native_shared_hardware_coordinator_v2` with required `mode`. `trust_only` accepts exactly schema/mode/listenAddress/certificateFile/certificateSHA256/keyFile, requires no preexisting NativePair catalog, and serves the real TLS handler without a selector goroutine. It accepts no devices, approval or pair result path. Existing Server registration/nonce ACK/SE/MDA/challenge/code-attestation paths remain unchanged; a nil catalog makes NewNativePairCoordinator return nil. This is not a trust-success claim. Root must retain a bounded process supervisor for this control-only session.

`one_request` additionally requires the original devices/approval/receiptFile. The prior approval limits, TLS file checks and selector/result body are unchanged. Missing/unknown mode, old schema, extra mode fields and preexisting catalog fail closed. The mode tests are staged, not run: actual loopback TLS/no selector, closed modes/fields, and retained one-request scope. They use an ephemeral fixture certificate and do not substitute for enrolled-device trust.

The e0 Swift/TLS composition a4a is separate. Root has now executed the separate b13 actual six-control TLS fixture successfully with unchanged b68 verifier; its actual HTTP observation proves the earlier failure was case-sensitive `WebSocket` handling in the test server. That result is not a Go/physical pair qualification. `TRUST_BOOTSTRAP.md` describes real control-only prerequisites; no trust flags or production records are fabricated here.
