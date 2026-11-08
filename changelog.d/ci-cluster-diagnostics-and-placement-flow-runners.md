### Provider CI: the diagnostics and placement flow runners compile, and CI runs them

- `provider-swift/Tests/ClusterDiagnosticsChecks/run.sh` and `provider-swift/Tests/ClusterPlacementChecks/run-flow.sh`
  compile again. Since 2026-11-04 both stopped at `cannot find 'GLM5NextGPULimitEligibility' in scope`, and CI ran
  neither, so nothing noticed.
- Shard 1 of Cluster Focused Checks now runs both, after the pairing runner, which adds about 2–3 minutes. A change
  that breaks either fails that shard.
- A change to `GLM5NextGPULimitEligibility.swift` alone now runs the cluster jobs too, as the other provider files
  that the cluster runners compile do: the console, diagnostics and placement flow runners compile it.
