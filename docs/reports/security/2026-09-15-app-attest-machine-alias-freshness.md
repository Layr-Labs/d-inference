# App Attest machine-alias freshness review

> Last updated: 2026-09-15 · commit `605651bb9`

The v0.9.4 machine inventory can make an old App Attest alias look freshly
verified without receiving a new assertion. Enforcement does not repair this
inventory path. This review assumes every provider has moved to macOS 27 and
therefore treats unsupported operating systems as out of scope.

The defect affects machine identity and adoption reporting. The inventory is
explicitly non-authoritative for serving and ledger identity, so this review
found no protected-serving bypass and no demonstrated balance or accounting
mutation.

## Scope and conclusion

After a successful endpoint-bound assertion, the live inventory session stores
the App Attest key ID in `VerifiedAppAttestKey`. A later failed exchange records
a prospective policy result but does not clear that stored key. While the
provider WebSocket remains alive, inventory captures run once per minute and
copy the latched key into a new observation.

PostgreSQL derives an `app_attest` alias from that copied key and upserts the
alias row with the capture's current `observed_at` value as `verified_at`. The
schema has no alias expiry or proof timestamp, and alias lookup does not filter
by age. A final capture runs at disconnect; periodic capture then stops, but the
alias row remains.

Consequently, `verified_at` can describe the most recent inventory heartbeat
rather than the most recent successful App Attest proof.

## Source evidence

| Claim | Evidence at the reviewed commit |
|---|---|
| A successful assertion latches the alias | `coordinator/api/app_attest_shadow_policy.go:60-67` (`observeBuildPolicy`) clears `VerifiedAppAttestKey`, then sets it to the verified key ID when revocation state is known and non-revoked. |
| A failed exchange leaves the prior alias latched | `coordinator/api/app_attest_shadow_policy.go:83-97` (`observeFailedPolicy`) records an `unknown` or `ineligible` prospective result but never changes the inventory observation. |
| A live WebSocket repeats the observation every minute | `coordinator/api/machine_inventory.go:51-65` (`startMachineInventory`) captures once, starts a one-minute ticker, and captures again on every tick until context cancellation. |
| Every capture reuses the latched key and gets a new time | `coordinator/api/machine_inventory.go:76-84` (`machineInventorySession.capture`) copies `x.observation` and sets `o.At = time.Now().UTC()`. |
| The key becomes an account-scoped alias | `coordinator/store/machine_inventory.go:61-80` (`MachineObservation.aliases`) hashes a non-empty `VerifiedAppAttestKey` into an `app_attest` alias scoped to the authenticated account. |
| Each repeated capture refreshes `verified_at` | `coordinator/store/postgres_machine_inventory.go:113-116` (`ObserveMachine`) upserts the alias and sets `verified_at` to the current observation's `o.At`. |
| Alias rows have no active-until value or TTL | `coordinator/store/machine_inventory_schema.go:8-12` defines only `kind`, `scope`, `digest`, `machine_id`, and `verified_at`; `ObserveMachine` looks up a matching alias without an age predicate. |
| Disconnect stops capture but does not remove the row | `startMachineInventory` performs one `capture(true)` when its context ends and returns. No disconnect path deletes or expires `darkbloom_machine_aliases`. |
| Inventory is not serving or ledger authorization | `coordinator/store/machine_inventory.go:11-12` states that a machine ID never authorizes a connection, changes a ledger key, or replaces live verification. |

## Why enforcement does not fix it

A correctly implemented enforcement gate evaluates live App Attest evidence for
protected dispatch. Machine inventory is a separate persistence path. Turning
on enforcement can reject a stale or failed provider connection while the same
connection's periodic inventory capture continues to advance the alias row's
`verified_at` field.

Moving all providers to macOS 27 removes the `unsupported` outcome but does not
remove transient assertion failures, coordinator failures, revocation, or an
expired assertion. Those states can still leave the inventory alias latched.

## Impact

The stale timestamp can overstate the freshness and continuity of App Attest
coverage in fleet dashboards, rollout/adoption reports, and machine-identity
analysis. Because an alias can also select an existing machine identity, future
inventory features that interpret `verified_at` as proof time could make
incorrect merge or assurance decisions.

This review does not classify the defect as a serving bypass. The current store
contract prevents inventory IDs from authorizing connections or changing
ledger keys, and enforcement should remain independent of this table. Nor does
the reviewed path establish a current payout, balance, or accounting mutation.

## Remediation

1. Record the successful assertion time and its authorization `valid_until`
   alongside the inventory alias. Never derive proof freshness from a periodic
   observation timestamp.
2. Separate durable historical association from current proof state. Fields
   such as `first_verified_at`, `last_proof_at`, and `active_until` make that
   distinction explicit; `verified_at` must not be advanced by a heartbeat.
3. Clear the live session's active App Attest alias on a failed exchange,
   revocation, assertion expiry, and disconnect. A later successful assertion
   can re-establish it.
4. Make current/adoption queries require an unexpired `active_until`. Historical
   alias rows may be retained for audit or identity continuity, but callers
   must not interpret their existence as current App Attest coverage.
5. Keep protected-serving authorization bound to the current connection and
   current evidence. It must never consult the machine-alias table as an
   eligibility cache.

## Acceptance criteria before enforcement

- After a successful assertion at time T, minute captures at T+1, T+2, and
  later do not change `last_proof_at` or extend `active_until`.
- A failed assertion or revocation removes the alias from current session
  observations and current-coverage queries.
- An otherwise live WebSocket loses active alias status when the assertion
  freshness deadline passes without another successful proof.
- The disconnect capture does not refresh proof time; the historical row may
  remain, but it is excluded from current App Attest adoption counts.
- A later valid assertion for the same key restores current status with its new
  proof time without creating an incorrect second machine identity.
- A regression test proves that routing authorization and ledger ownership do
  not read machine aliases.
- Dashboard and rollout queries state whether they report historical
  association or currently valid App Attest coverage.

## Review boundary

This source review proves the timestamp-refresh mechanism and persistent row.
It does not establish that a current production dashboard consumes
`verified_at` as proof time or that an incorrect merge or accounting event has
already occurred. Those would require query-level and production-data review.
