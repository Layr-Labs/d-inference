# Current-master authorization event compatibility

Master's `CoordinatorEvent.trustStatus` now includes optional `ProviderAuthorizationStatus`. Its type explicitly identifies diagnostics and migration guidance, not a local private-serving or native-start grant. `CoordinatorClient+Inbound` carries the complete object and the existing `ProviderLoop+Serve` switch forwards all four fields to `handleTrustStatus`, which persists it for status/doctor and clears old authorization when a legacy nil update arrives.

The one runtime hunk updates the member interceptor's tuple arity. It retains the original explicit `untrusted`/`offline` stop rule and returns false so the existing master dispatcher still receives the complete event. It does not infer pair permission from App Attest diagnostics, and does not reject a legitimate online App Attest path merely because its legacy trust level is `self_signed`. Actual coordinator lease expiry/revocation, native grant verification and original owner cleanup remain separate existing mechanisms.

One new test exercises both actual member/trust handlers: online authorization passes through and persists, a nil legacy update clears that object, no work/native member is created, and an untrusted event still closes the accepted member generation despite a current-looking diagnostic object. A later connected event cannot revive the stop latch. Existing 192 labels remain; the completion contract is now exact 193. The existing parameterized case grammar and all five starts remain unchanged.

The original f162 runner, a764 candidate, copied-PCM failure, root 62413 cache retry, tests-2 failure and raw logs are pinned and preserved. The only compilation-input deltas are one Provider runtime source and its existing test file. No SDK/dependency/helper source changes. The actual six-step helper receipt 7dd276da is reused with exact artifacts; it is not rebuilt. All 14,111 source/checkout inputs are checked before and after preparation and each owned compile. Master/MAIN remain untouched: the preparation applies only to the already disposable f162 scratch workspace, retaining original source bytes. `overlay.json` and the patch also give root the exact eventual master promotion preimages.

After root review and a free compiler slot:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-product-member-authorization-event-20260920
python3 -B check_sources.py
python3 -B run.py prepare
python3 -B run.py tests
python3 -B run.py build
```

Use regular controller stdout/stderr files. Preparation remains owned/120 seconds; tests and matching CLI each remain owned/900 seconds, jobs=2, 4 MiB diagnostic parsing and 512 MiB compiler-file ceiling. No automatic resolution, private define, retry, original cache mutation, remote action, hardware operation, signing or trust qualification. The correction and regression are source-only until root executes these commands.

Applicable repository AGENTS requirements: preserve mirrored protocol semantics, independent trust/capacity gates and cleanup, keep changes modular, and use meaningful existing package tests. There is no wire shape change here, only a consumer updated for the already mirrored upstream event.
