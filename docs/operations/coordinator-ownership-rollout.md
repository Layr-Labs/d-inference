# Coordinator Ownership Rollout

The PostgreSQL advisory ownership lock and orphan-reservation recovery require
a two-restart rollout. An old coordinator does not hold the lock; enabling
ownership on a new container while the old one is live would let the new
container misidentify active old-process reservations as orphaned.

## Prerequisites

- The patched Go image is deployed with
  `EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED` unset/false.
- The detailed coordinator drain is at zero.
- No Rust coordinator or recovery process is connected to the database.

## Steps

1. Deploy the patched image with ownership disabled. It behaves like the
   previous single-container release and does not recover reservations.
2. Put that patched process into drain and wait for quiescence.
3. Stop the process completely.
4. Set `EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true`.
5. Start the same patched image. It acquires the dedicated PostgreSQL advisory
   lock before serving, drains every orphaned reservation batch, and then opens
   admission.
6. Keep ownership enabled on every later Go/Rust image.

Future swaps are serial handoffs: the old lock holder must stop before the new
instance can become ready. A second instance fails startup rather than serving
concurrently.

## Verification

- Startup logs contain no ownership conflict.
- A second test instance against the same database refuses startup.
- `/readyz` becomes unavailable and the process terminates if the dedicated
  ownership connection is lost.
- Orphan recovery reaches zero before public admission.

## Rollback

Do not disable ownership after activation. Drain and stop the current owner,
then start the tested rollback image with ownership enabled. If the rollback
image predates ownership support, complete the Rust/Go recovery procedure
before using it.
