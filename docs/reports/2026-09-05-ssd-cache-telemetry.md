# SSD cache heartbeat telemetry validation

> Last updated: 2026-09-05 · commit `ac1dc301c`

This milestone adds typed SSD observations to the live provider heartbeat and
coordinator metrics path. It does not enable paged attention or change cache
routing defaults. The code was reviewed independently of the parallel renderer,
allocator and holder-index work.

## Change and checks

Per-store snapshots report cache kind, sample generation, sequence and age,
disk/index/staging usage, and cumulative activity. Complete checkpoints add I/O
and duration totals. Whole-root removal counts are process-wide. The coordinator
emits fresh observations once, computes counter deltas within one generation,
and retains age for repeated samples. Missing instrumentation remains absent.
Metrics use bounded tags and carry no prompt, token, scope or artifact identity.

Complete-checkpoint donation outcomes use the existing once-only outcome channel.
The complete-store `donation_drops_total` observation counts queued write drops;
prequeue refusals are represented by donation outcomes. Aggregate artifact-list
status distinguishes unrestricted configuration from a configured empty list.
An existing memory cache hint now reports its actual tier.

Review found that taking the filesystem maintenance lock for a stats snapshot
could block heartbeats behind an SSD sweep. Publication and snapshot copying now
use a separate short lock. A regression pauses an actual sweep at the active-store
mutation barrier and verifies that a snapshot completes before the sweep resumes.

| Validation | Result |
|---|---|
| Go 1.25.0, all coordinator packages on an isolated baseline plus the staged Go patch | 25 packages passed; API suite 154.894 seconds |
| Affected protocol, registry and heartbeat/Datadog race checks | Passed, including actual UDP metric collection and tier labeling |
| Swift semantic build of the integrated source capture | Passed, 133.51 seconds |
| Eight new telemetry/donation/concurrency tests and existing affected cache lifecycle suites | Passed |
| Docs check | 135 pages passed before this report was added |

The combined Swift run contained 72 tests in 13 suites and reported three issues
in two tests outside this milestone: renderer whitespace expectations and a
GPT-OSS reasoning-effort parity mismatch. Its full failure log is retained; this
report makes no full-provider-suite pass claim. Those tests exercise separate
uncommitted renderer work.

The first isolated Go run omitted three source/config fixtures from its sparse
checkout. Restoring them from the same baseline made the full rerun pass; both
logs are retained. One blank EOF line was removed from a new Swift type file after
compilation. The evidence records both hashes and that cosmetic-only change.

## Evidence and limits

[The evidence manifest](evidence/ssd-cache-telemetry-2026-09-05/manifest.json)
contains final staged source hashes, the isolated Go source capture, the combined
Swift source capture, and compressed logs with stored and uncompressed hashes.
Manifest SHA-256:
`e51641104892ef27fbab21f252f002f720a79eb1bc284ebd3516a13614369275`.
Every staged Swift file matches the compiled capture except the documented EOF
cleanup; every staged Go file matches the isolated verification tree.

These checks establish instrumentation behavior, lifecycle ownership and wire
compatibility. They do not establish fleet hit rate, paged performance, physical
RAM reclamation, persistent-key process restart, or live multi-machine latency.
No deployment or production configuration change was performed.
