#!/bin/bash
# Validate and atomically install the host TLS proxy configuration.
set -euo pipefail

[[ $# -eq 1 ]] || {
  echo "usage: configure-caddy.sh {dev|prod}" >&2
  exit 64
}
ENVIRONMENT=$1
case "$ENVIRONMENT" in
  dev)
    DOMAIN=api.dev.darkbloom.xyz
    ;;
  prod)
    DOMAIN=api.darkbloom.dev
    ;;
  *)
    echo "usage: configure-caddy.sh {dev|prod}" >&2
    exit 64
    ;;
esac

command -v caddy >/dev/null 2>&1 || {
  echo "caddy is unavailable" >&2
  exit 1
}
install -d -m 0755 /etc/caddy
temporary=$(mktemp /etc/caddy/Caddyfile.XXXXXX)
trap 'rm -f "$temporary"' EXIT

cat >"$temporary" <<EOF
${DOMAIN} {
  handle /scep {
    reverse_proxy https://127.0.0.1:9002 {
      transport http {
        tls_insecure_skip_verify
      }
    }
  }
  handle /mdm/* {
    reverse_proxy https://127.0.0.1:9002 {
      transport http {
        tls_insecure_skip_verify
      }
    }
  }
  reverse_proxy 127.0.0.1:8080 {
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Host {host}
    header_up -Forwarded
    header_up -X-Real-IP
    header_up -CF-Connecting-IP
    header_up -True-Client-IP
    health_uri /health
    health_interval 30s
    health_timeout 5s
    health_status 200
  }
  request_body {
    max_size 25MB
  }
  header {
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
    -Server
  }
  log {
    output stdout
    format console
    level INFO
  }
}
EOF

caddy validate --config "$temporary" --adapter caddyfile >/dev/null
install -m 0644 "$temporary" /etc/caddy/Caddyfile
systemctl reload-or-restart caddy.service
