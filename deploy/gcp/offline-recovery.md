# Offline recovery service

`d-inference-recovery.service` runs `coordinator-rs recovery` from the same
image pinned in `DINF_IMAGE`. It acquires the same PostgreSQL coordinator owner
lock as the serving process, so it is an offline maintenance mode, not a
sidecar.

To run it, drain and stop `d-inference-coordinator.service`, verify no serving
container remains, create `/etc/d-inference/enable-offline-recovery`, and start
`d-inference-recovery.service`. The units do not use `Conflicts=`: both wrappers
hold the same host lock and explicitly refuse overlap, so starting recovery can
never silently stop serving. The Rust recovery command also acquires the shared
PostgreSQL ownership lock itself. Remove the enable file and stop recovery
before restarting the serving unit.
