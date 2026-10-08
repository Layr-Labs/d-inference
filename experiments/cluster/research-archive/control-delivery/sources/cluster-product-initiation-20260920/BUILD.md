# Qualification after reviewed current-master composition

No build/preparation is authorized by this source package. Root schedules all
compilers; do not modify the existing base while another package is qualified.

1. Run `python3 -B check_sources.py` for small source/metadata checks only.
2. Compose exact known predecessors plus this 22-file overlay in root's
   separately reviewed master/private composition. Reconcile api/provider.go
   with cc225365 App Attest service dispatch and preserve its trust checks.
   The required identity-kind successor must be explicit; no stale legacy
   verifier may be presented as App Attest qualification.
3. In the resulting private Go tree, first run the exact named eight new
   protocol/registry methods, retaining original local WS fixture cleanup.
   Then run all native pair/verified pair and routing/API regression coverage.
   Suggested first command is `go test -timeout 120s ./protocol ./registry
   -run '^TestNativePair(Intent|Configured)'`; use root's owned process wrapper,
   jobs/lifetime/output bounds and disjoint coverage procedure for broad API.
4. In the private Provider tree, add the five listed Swift methods/suites to
   actual discovery and the previous product/HTTP coverage. Require every
   discovered intended method's completion; do not guess a total after master
   changes. Use `swift test -j 2 --disable-automatic-resolution
   --disable-build-manifest-caching --filter ...` with root's existing bounded
   runner, matched helper and complete before/after source/dependency maps.
5. Build the matching CLI only after the combined tests pass. A separate
   current catalog, genuine release/signing configuration, both verified live
   members and mutually configured consent are required for later physical
   execution. The empty catalog or absent signing inputs never authorize it.

There is no new owner, SSH request route, plaintext fallback, native workload
expansion or public-serving declaration in these commands.
