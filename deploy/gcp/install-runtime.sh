#!/bin/bash
set -euo pipefail

SOURCE_DIR=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

install -d -m 0755 /usr/local/lib/d-inference /usr/share/doc/d-inference
install -m 0755 "$SOURCE_DIR/configure-caddy.sh" /usr/local/bin/d-inference-configure-caddy.sh
install -m 0755 "$SOURCE_DIR/run-coordinator.sh" /usr/local/bin/d-inference-run.sh
install -m 0755 "$SOURCE_DIR/run-recovery.sh" /usr/local/bin/d-inference-recovery-run.sh
install -m 0644 "$SOURCE_DIR/deploy-common.sh" /usr/local/lib/d-inference/deploy-common.sh
install -m 0644 \
  "$SOURCE_DIR/systemd/d-inference-coordinator.service" \
  /etc/systemd/system/d-inference-coordinator.service
install -m 0644 \
  "$SOURCE_DIR/systemd/d-inference-recovery.service" \
  /etc/systemd/system/d-inference-recovery.service
install -m 0644 \
  "$SOURCE_DIR/offline-recovery.md" \
  /usr/share/doc/d-inference/offline-recovery.md

systemctl daemon-reload
systemctl enable d-inference-coordinator.service
systemctl disable d-inference-recovery.service >/dev/null 2>&1 || true
