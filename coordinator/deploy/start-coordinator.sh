#!/bin/sh
set -eu

# ============================================================================
# start-coordinator.sh — swappable "coordinator-only" half of the split.
# (DAR-327 Phase 2)
#
# This is the half that blue-green swaps. The long-lived platform
# (start-platform.sh) already owns step-ca, MicroMDM and first-boot init of the
# shared /mnt/disks/userdata volume. This script therefore does the bare
# minimum a fresh per-color container needs:
#   1. re-create the /data -> persistent-volume symlink inside THIS container
#   2. wait (bounded) for the platform to publish the step-ca root cert
#   3. exec the coordinator, honoring EIGENINFERENCE_PORT (blue=8080, green=8081)
#
# It deliberately does NOT init/run step-ca, run MicroMDM, or do any first-boot
# work — that belongs to the platform and must not run per color (running two
# step-ca/MicroMDM instances against the same volume would corrupt state).
# ============================================================================

PERSIST="${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}"

# Each container has its own root filesystem; the volume bytes are shared via
# the bind mount, but the /data symlink is per-container. Re-create it so the
# coordinator finds the step-ca certs at EIGENINFERENCE_STEP_CA_ROOT
# (default /data/step-ca/certs/root_ca.crt).
ln -sfn "$PERSIST" /data

# Bounded wait for platform first-boot init so a cold box (coordinator started
# before the platform finished initializing the CA) doesn't crash-loop.
CA_ROOT="${EIGENINFERENCE_STEP_CA_ROOT:-/data/step-ca/certs/root_ca.crt}"
WAIT_SECS="${COORDINATOR_PLATFORM_WAIT_SECS:-60}"
i=0
while [ ! -f "$CA_ROOT" ]; do
    if [ "$i" -eq 0 ]; then
        echo "start-coordinator: waiting (up to ${WAIT_SECS}s) for platform step-ca root cert at $CA_ROOT ..."
    fi
    if [ "$i" -ge "$WAIT_SECS" ]; then
        echo "start-coordinator: WARNING: $CA_ROOT still absent after ${WAIT_SECS}s; starting anyway." >&2
        break
    fi
    i=$((i + 1))
    sleep 1
done

echo "start-coordinator: starting coordinator on port ${EIGENINFERENCE_PORT:-8080}..."
exec coordinator
