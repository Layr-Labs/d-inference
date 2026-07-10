# Rust Coordinator — Explicit Decisions

Status: active during migration  
Date: 2026-07-10

## Open decisions (§29) — locked for execution

| # | Decision | Choice |
| --- | --- | --- |
| 1 | Public consumer pricing | Provider-independent public price per model |
| 2 | Provisional reservation | Coordinator upper bound from request shape + max_tokens + model price |
| 3 | One-phase pre-funded fast path | Out of scope until property tests exist |
| 4 | Prepared-lease TTL / ACK | TTL 15s; abort/cancel ACK wait 5s |
| 5 | Internal queue | None for public/OpenRouter; 429 + Retry-After |
| 6 | Terminal journal | Encrypted local file, 10k entries / 64 MiB |
| 7 | Terminal canonicalization | Domain-separated canonical JSON + SE signature |
| 8 | Protocol-v2 fleet floor | Explicit capability flag (not semver) |
| 9 | DB placement | Same-zone Postgres required before Milestone 5 |
| 10 | Emergency Go before Rust reconcile | No |
| 11 | Prepare hedge | p95 prepare trigger; ETA miss vs remaining TTFT; 5% global budget |
| 12 | Binary payload header | Fixed 64-byte header + ciphertext |
| 13 | Half-open recovery admits | `AdmitRequest.allow_half_open_probe`; general traffic stays Healthy\|Suspect only |
| 14 | Sequential alternate after prepare expiry | At most **one** alternate; second PrepareExpired finalizes (no attempt ladder) |
| 15 | Job ID reuse | **Forbidden.** `MemoryLedger.reserve` / start_authorized reject existing or disposed `job_id` (new UUID per job) |
| 16 | Release after start_authorized | **Forbidden.** Must settle (or recovery-review); prevents refund of funded attempts |

## Deleted Go mechanisms (do not port)

See architecture plan §27.
