#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]] || [[ "$1" != /* ]] || [[ "$2" != /* ]]; then
    echo "usage: $0 /absolute/install/parent /absolute/staging/tree device:inode" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${DARKBLOOM_LUME_PYTHON:-$(command -v python3)}"
exec "$PYTHON" "$SCRIPT_DIR/lume-runtime-publication.py" cleanup "$1" "$2" "$3"
