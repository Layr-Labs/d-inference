# Check a missing base reward

> Last updated: 2026-10-25

A green `doctor` and live inference rows do not prove the coordinator granted
`model=base_reward` for a 5-minute period. There is no CLI field that names the
reason a period paid $0. This page is the local check; it does not change
routing or payouts.

Current backend behavior is owned by the
[platform's latest default branch](https://github.com/Layr-Labs/darkbloom-platform/tree/master).
Immutable citations below are evidence snapshots, not current source or proof
of deployed policy.

## Prerequisites

- The provider is installed and the daemon is running (`darkbloom status`).
- You can sign in at `https://console.darkbloom.dev`. There is no
  `darkbloom earnings` CLI command ([quickstart](quickstart.md#earnings-and-billing)).
- An administrator macOS account if you will upload a report (system log
  access). Otherwise the report still uploads the App Attest snapshot.

## Steps

1. Confirm the Mac is locally healthy.

   ```bash
   darkbloom doctor --strict
   darkbloom status
   ```

   `doctor` billing is **local usage reporting** for the current session
   (`provider-swift/Sources/darkbloom/Diagnostics/DoctorRunner.swift`,
   `usage reporting`). It is not a coordinator base-reward grant.

2. Open the console earnings view at `https://console.darkbloom.dev`.

   The desktop account view splits the same feed into work vs
   `model=base_reward`
   (`provider-swift/Sources/darkbloom/Desktop/DesktopAccountEarnings.swift`).

3. In the last-1000 earnings rows, count `model=base_reward` separately from
   inference models.

   A row with `model=base_reward` is a subsidy settle, not a completion. Tokens
   on that row are typically 0. Absence of the label, or a 5-minute amount that
   matches a smaller RAM class than this Mac, is the signal this page is for.

4. Compare a 5-minute `base_reward` amount to the **last-public** floor table
   only as a snapshot. Do not treat it as deployed policy.

   Last published in this repository at
   [`080d7e667`](https://github.com/Layr-Labs/d-inference/blob/080d7e66782b28ab038f34dfb5ce23469f19642b/coordinator/payments/baserewards/engine.go)
   (`floorTiers`, amounts in micro-USD / month):

   | Unified memory | Last-public monthly floor |
   |---|---|
   | 24 GB | $8 |
   | 36 GB | $12 |
   | 48 GB and 64 GB | $18 |
   | 96 GB and 128 GB | $24 |
   | 192 GB | $30 |
   | 512 GB | $40 |

   There is no 256 GB row in that snapshot. A catalogued 256 GB Mac would take
   the 192 GB tier ($30 / month) if those constants still applied.

   Same snapshot: 48–96 GB machines were the **workhorse** band
   ([`alloc.go` @ `080d7e667`](https://github.com/Layr-Labs/d-inference/blob/080d7e66782b28ab038f34dfb5ce23469f19642b/coordinator/payments/baserewards/alloc.go),
   `isWorkhorse`, `WorkhorseReserveFrac`). 128 GB, 192 GB, 256 GB and 512 GB
   were outside that band. Allocator source is no longer in this tree.

5. If `doctor` is green and `base_reward` is missing or far below that RAM
   class, collect a report. Do not paste hostnames, serials, provider keys, or
   tokens into a public issue.

   ```bash
   darkbloom doctor --support > doctor.txt
   darkbloom report --last 24h --dry-run
   darkbloom report --last 24h
   ```

   Quote the printed `report_id` to support. Cite
   [issue 1601](https://github.com/Layr-Labs/d-inference/issues/1601) if the Mac
   is 256 GB or 512 GB class and a 48–96 GB peer printed a full 64 GB-sized
   period at the same time.

## Verify

- `doctor --strict` completed. A pass still does not explain a $0 base-reward
  period.
- Console last-1000 either contains `model=base_reward` rows or you recorded
  that it does not.
- You have a `report_id` if you asked support to look.

## Troubleshooting

| What you see | What it is not | What to do |
|---|---|---|
| `doctor` red / ⚠ | A base-reward ranking problem | Fix [troubleshooting](troubleshooting.md) first |
| `doctor` green, no `base_reward` rows | Proof the Mac is ineligible, ranked out, or in a settlement bug — those three are not distinguishable from the provider | Upload `darkbloom report`; cite [issue 878](https://github.com/Layr-Labs/d-inference/issues/878) and [issue 1601](https://github.com/Layr-Labs/d-inference/issues/1601) |
| Tiny inference jobs still paying list (short completions, `model` is Gemma / other catalog) | A missing base reward | Different path: demand / job mix, not this subsidy check |
| Unknown `HardwareModel` / new Mac identifier | A ranking miss. Last-public engine skipped uncatalogued models entirely | [Issue 1553](https://github.com/Layr-Labs/d-inference/issues/1553); include `darkbloom status` hardware fields in the report |

## Related

- [Quickstart — earnings and billing](quickstart.md#earnings-and-billing)
- [Hardware requirements](hardware-requirements.md)
- [Troubleshooting](troubleshooting.md)
- [CLI reference — `darkbloom report`](cli-reference.md)
