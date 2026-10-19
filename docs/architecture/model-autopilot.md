# Provider Autopilot

> Last updated: 2026-10-09

Provider Autopilot offers explicitly consented cached models to an external
controller. Interest or shadow enrollment does not authorize live control,
downloads, higher earnings or relaxed memory limits.

## Mechanism

`ModelAutopilotSettings` in
`provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotSettings.swift`
owns consent and selected-model eligibility. Ordinary startup selection remains
separate. The provider publishes typed snapshots, validates control leases and
rechecks actual work, pins, inventory and memory before changing residency.

| Responsibility | Provider source |
|---|---|
| Control lifecycle, expiry and clearing | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotControl.swift` |
| Command policy and terminal results | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+Autopilot.swift`, `ModelAutopilotPolicy.swift` in the same directory |
| Cached target preparation and ordinary load safeguards | `provider-swift/Sources/ProviderCore/Autopilot/ProviderLoop+AutopilotInventory.swift` |
| Load-time history | `provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotHistory.swift` |

Failed or expired control cannot manufacture ownership of accepted work.
Cancellation, disconnect and shutdown must preserve native retirement and
restore ordinary serving eligibility only through the existing lifecycle.
Files already on disk are not evidence that a model can load safely.

## External Policy

Machine selection, demand planning, rewards, accounting and rollout controls
belong to [platform Autopilot](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/model-autopilot.md).
Do not administer those systems by reintroducing backend code here. Wire changes
require coordinated review; fixed provider fixtures alone do not qualify live
controller behavior or a production cohort.

## Related

- [CLI settings](../provider/cli-reference.md)
- [Configuration](../reference/configuration.md)
- [Protocol](../reference/protocol-messages.md)
- [Memory safeguards](hardware-support.md)
