#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]] || [[ "$1" != /* ]] || [[ "$2" != /* ]]; then
    echo "usage: $0 /absolute/install/parent /absolute/staging/tree" >&2
    exit 2
fi

INSTALL_PARENT="$1"
STAGING_DIR="$2"
if [[ ! -e "$STAGING_DIR" && ! -L "$STAGING_DIR" ]]; then
    exit 0
fi
if [[ "$STAGING_DIR" != "$INSTALL_PARENT"/.darkbloom-lume-install.* ]] \
    || [[ -L "$STAGING_DIR" ]] \
    || [[ ! -d "$STAGING_DIR" ]]; then
    echo "refusing unsafe Lume staging cleanup path: $STAGING_DIR" >&2
    exit 1
fi

# The runtime tree is intentionally read-only before atomic publication.
# Restore access and clear inherited ACLs only within that owned staging tree.
/bin/chmod -RN "$STAGING_DIR" 2>/dev/null || true
/bin/chmod -R u+rwX "$STAGING_DIR"
/bin/rm -rf -- "$STAGING_DIR"
