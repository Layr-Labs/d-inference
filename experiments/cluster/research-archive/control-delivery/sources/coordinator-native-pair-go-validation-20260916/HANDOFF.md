# Corrected coordinator native-pair Go qualification

Source-only successor of the member validation wrapper `0550d8fb270ac4dbef474fc0585497d7bf8c612ca35812cca6f76ac6ade2be06`. No workspace, compiler, child process, model, remote operation or MAIN mutation has been performed by this package. The original member wrapper, prepared workspaces and failed attempts remain unchanged.

Composition, in order:

1. Current dirty MAIN, exactly pinned by `source-preview.json` and all overlay preimages.
2. Registered member overlay `4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965`.
3. Native-pair coordinator B `69189730ac9df0ced27006c2b00606583a20f905a7140cfc8fff5f24ff9dc500`.
4. Cancellation publication correction `4339ee6034187060459c11b4879f722318aee2578f2d44bbf6936e3715e80745`.

The complete conservative Go import/test/embedded-resource closure is 1,111 files: 1,079 MAIN, 11 member, 18 original B and three correction sources. The public transcript vector under protocol/testdata is included. The five prior real repository fixtures remain byte-exact: prompt-contract production vectors, three production deployment inputs, and scripts/install.sh. All MAIN/effective overlay preimages, every manifest member, B's 29 contextual dependencies, exact inherited owned-process helpers and the unchanged anonymous-metallib binder context are checked before copying. The reviewed complete inventory must match before preparation and before/after execution; an old member-only workspace is refused. No source reset, checkout, tracked-file write or global cache copying occurs.

Only inputs.py, guards.py, prepare.py and run.py differ from the upstream wrapper. The scoped entrypoints expose Go preparation/focused/all phases; the original Swift runner remains in its unchanged package. `check_process.py`, `owned_process.py`, `source_inventory.py`, helper-lineage, binder-review and fixture-inputs are exact upstream bytes. In particular, compiler ownership/reaping and unreaped-only group signal behavior are inherited unchanged.

After explicit root grant, use a fresh output sibling and run these commands sequentially from this directory. Run the full phase only if focused checks report PASS; preserve a failed directory and do not overwrite it.

```sh
/usr/bin/python3 -B prepare.py --phase go --output /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-go-build-1-20260916
/usr/bin/python3 -B run.py --phase go-focused --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-go-build-1-20260916 --attempt 1
/usr/bin/python3 -B run.py --phase go-all --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-go-build-1-20260916 --attempt 1
```

Each execution uses pinned Go 1.25.0, `-race -p 2 -count=1`, `GOMAXPROCS=2`, offline locked dependencies (`GOPROXY=off`, `GOSUMDB=off`, `GOTOOLCHAIN=local`, `GOWORK=off`, `-mod=readonly`), and the actual registry, protocol and API test packages. Focused selection is `^Test(NativePair|VerifiedPair|ClusterMember|MemberRole)`. Focused package timeout stays 120 seconds; full package timeout stays 180 seconds; each owned parent stays 300 seconds. Diagnostic retention/parsing stays 16 MiB and process file size stays 512 MiB. No native/model/request deadline changes.

Both phases require complete package PASS events plus all 15 VerifiedPair methods, four member methods and the exact 16 NativePair methods listed in inputs.py. That includes two actual API handler tests and the deterministic pending-cancellation publication/reuse regression. Full output retains every other package method result; no assertions or skips are rewritten. The runner preserves raw stdout/stderr, launch observation, natural return code and owned-child reaping/group absence, then checks all source pins again before declaring success.

Qualification scope is coordinator CPU behavior and public protocol binding only. It does not qualify the new Swift mirror, provider-side owned-child invocation, native file/gate verification, production membership deployment, key confirmation over a real relay, GPU inference or encrypted RDMA. Those remain separate increments; default native approval stays disabled, current hardware/model gates remain unchanged, and no public hash confers runtime approval.

Independent corrected B source review is retained separately at `coordinator-native-pair-authorization-review-20260916/source-review.json` (`695bf3dce75e96a9caa61bed3d28c2aef2c9bd28a9989af355d199859f237133`). Wrapper review is pending at freeze. Local preparation checks performed here are Python AST, exact manifest/preimage/helper checks, complete source-inventory discovery and equality, and exact test-method discovery; they do not execute Go tests.
