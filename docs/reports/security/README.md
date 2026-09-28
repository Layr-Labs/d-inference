# Security reports

> Last updated: 2026-09-15 · commit `605651bb9`

Dated security reviews and validation records. Each report describes the code
at its stamped commit and separates observed behavior from the effect of a
future enforcement or rollout decision.

## App Attest enforcement review

These reports assume every enforced provider runs macOS 27. They record gaps
that enabling enforcement alone does not repair:

- [Retry freshness](2026-09-15-app-attest-enforcement-retry-freshness.md) — the recovery ladder can outlive the assertion-freshness window.
- [Coordinator backpressure](2026-09-15-app-attest-enforcement-coordinator-backpressure.md) — coordinator-local failures consume the provider recovery budget.
- [Receipt-renewal capacity](2026-09-15-app-attest-enforcement-receipt-renewal-capacity.md) — fixed per-replica throughput can age receipt readiness beyond its allowance.
- [Machine-alias freshness](2026-09-15-app-attest-machine-alias-freshness.md) — inventory capture can refresh an alias timestamp without a new assertion.
- [Live dispatch authorization](2026-09-15-app-attest-live-dispatch-authorization.md) — durable observations cannot replace a current connection-bound dispatch decision.
- [Revocation at dispatch](2026-09-15-app-attest-revocation-at-dispatch.md) — cached assertion-time readiness can retain revoked eligibility.
- [Owner self-routing](2026-09-15-app-attest-self-route-enforcement.md) — the legacy owner trust relaxation must not bypass App Attest authorization.
