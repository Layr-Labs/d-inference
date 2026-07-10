# Rust Coordinator

This directory tracks the Go → Rust coordinator migration.

- Architecture plan: user-provided (2026-07-10)
- Locked decisions: [DECISIONS.md](./DECISIONS.md)
- Contracts: [contracts/](./contracts/)
- Code: `coordinator-rs/`

## Workspace

```text
coordinator-rs/
  crates/protocol  — wire types + crypto
  crates/core      — pure reducers / admission / health
  crates/server    — Axum + actors + SQLx (M3+)
```

## Build

```bash
cd coordinator-rs && cargo test --workspace
```

## Ops docs

- [DECISIONS.md](./DECISIONS.md) — locked §29 defaults
- [PILOT.md](./PILOT.md) — Milestone 5 isolated pilot
- [CUTOVER.md](./CUTOVER.md) — Milestones 7–8 cutover/rollback
- [UNSUPPORTED.md](./UNSUPPORTED.md) — pilot route matrix
- Contracts: [contracts/](./contracts/)
