# Coordinator migration ownership matrix

This matrix separates evidence collection, approval, production mutation, and
incident authority. One person may hold multiple roles only when the
organization's separation-of-duties policy permits it; the gate signer and
human approver keys remain distinct.

## Prerequisites

- Named primary and backup owners are recorded before `sampled-shadow-replay`.
- Public verification keys and rotation dates are recorded with release
  security. Private keys are not stored with gate artifacts.
- Production deploy and database access continue to follow
  [`coordinator-deploy.md`](coordinator-deploy.md).

## Steps

Assign the following responsibilities:

| Activity | Responsible | Accountable | Consulted | Informed | Prohibited |
|---|---|---|---|---|---|
| Fault/load/differential CI | Coordinator engineering | Coordinator tech lead | Provider + payments | Release ops | Production credentials |
| Read-only coordinator/Datadog/RDS collection | Observability operator | On-call lead | DBA + security | Release ops | DDL/DML, traffic changes |
| Gate policy/version changes | Release security | Security lead | Coordinator + SRE | Approvers | Same-change self-approval |
| Assessment signing | Release security | Release security lead | Evidence owners | Human approver | Production mutation |
| Explicit gate approval | Named human release approver | Release owner | Security + on-call | Stakeholders | CI/agent approval |
| Dedicated canary listener/DB | Canary environment owner | Release owner | On-call + DBA | Stakeholders | Production DB or money |
| Atomic production binary handoff | Human production operator | Release owner | On-call + DBA | Stakeholders | Agent/CI execution or dual DB owners |
| Additive schema migration | Human DBA/release operator | Database owner | Go + Rust owners | On-call | Serving startup DDL |
| Go fallback decision | Incident commander | On-call lead | DBA + payments + security | Stakeholders | Bypassing rollback guard |
| Reviewed financial disposition | Payments operator | Payments lead | Incident commander | Audit | Unjournaled row edits |
| Provider protocol-v1 retirement | Provider owner | Coordinator tech lead | Release ops + support | Providers | Retirement with v1 count > 0 |
| Go binary/code retirement | Coordinator owner | Engineering lead | Security + SRE + payments | Organization | Retirement before 90d gate |
| Evidence archive and key rotation | Release security | Security lead | Compliance | Engineering | Editing signed history |

Record ownership changes as a reviewed documentation change before the next
gate. During an incident, the incident commander can stop progression but
cannot manufacture an approval or waive a failed check.

## Verification

- Every row has named primary and backup people in the internal on-call system.
- Gate assessments and human approvals have different trusted key IDs.
- Workflow permissions remain `contents: read` and contain no production
  environment or deployment job.
- RDS collection proves a read replica, read-only transaction, non-elevated
  role, and zero write privileges.
- The production operator can identify the last authorized gate and pinned Go
  image without access to a private evidence-signing key.

## Rollback

If an owner is unavailable or key custody is uncertain, stop progression.
Rotate the affected key, update the trusted public-key inventory through
review, and generate new evidence and approval. Do not transfer a private key,
reuse an old approval, or collapse assessment, approval, and deployment into
an automated role.

