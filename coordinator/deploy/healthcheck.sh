#!/bin/sh
set -eu

port=${EIGENINFERENCE_PORT:-8080}
case "$port" in
    *[!0-9]*|'')
        exit 1
        ;;
esac

wget -q -T 5 -O - "http://127.0.0.1:${port}/health" |
    jq -e '.status == "ok"' >/dev/null
