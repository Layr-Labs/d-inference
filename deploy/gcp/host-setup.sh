#!/bin/bash
# Dev only. Sets up the host of the dev coordinator VM d-inference-dev. A human
# runs it as root over IAP SSH, from a copy of deploy/ at a reviewed master
# commit. It is not a startup script. It is idempotent.
#
#   host-setup.sh [--check]  read only: print PASS or FAIL for each item (default)
#   host-setup.sh --apply    make each item true; refuses to format a blank disk
#   host-setup.sh --apply --format-data-disk
#                            one-shot authorization to format the verified blank data disk
#
# Items: packages (docker, caddy, google-cloud-cli, jq, postgresql-client, python3),
# Docker credentials for Artifact Registry, the data disk at
# /mnt/disks/userdata, the production env refresh unit and manifests (installed
# as in docs/operations/coordinator-deploy.md step 3), the host Caddyfile, and
# the Datadog Agent when /etc/d-inference/env has DD_API_KEY.
#
# It writes no env value and starts no coordinator container. --apply reloads
# Caddy only when the Caddyfile changes. Do not run --apply during a swap: a
# Caddy reload reconnects every provider. It refuses to run outside the GCP
# project darkbloom-dev.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MODE=--check
FORMAT_DATA_DISK=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check|--apply) MODE=$1 ;;
        --format-data-disk) FORMAT_DATA_DISK=1 ;;
        *) echo "usage: $0 [--check|--apply] [--format-data-disk]" >&2; exit 2 ;;
    esac
    shift
done
[ "$FORMAT_DATA_DISK" = 0 ] || [ "$MODE" = --apply ] || {
    echo "--format-data-disk requires --apply" >&2
    exit 2
}
PROJECT=darkbloom-dev
METADATA_URL=http://metadata.google.internal/computeMetadata/v1/project/project-id
REGISTRY=us-east4-docker.pkg.dev
DATA_DEV=/dev/disk/by-id/google-darkbloom-coordinator-data
DATA_MOUNT=/mnt/disks/userdata
ENV_FILE=/etc/d-inference/env
ENVLIB=/usr/local/lib/darkbloom-env
REFRESH_BIN=/usr/local/sbin/darkbloom-refresh-env
UNIT=/etc/systemd/system/darkbloom-env-refresh.service
CADDYFILE=/etc/caddy/Caddyfile
PROD=$SCRIPT_DIR/prod
OVERRIDES=$SCRIPT_DIR/dev/env-overrides

die() {
    echo "FAIL $*" >&2
    exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"
project=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' "$METADATA_URL") ||
    die "cannot read the project from the metadata server"
[ "$project" = "$PROJECT" ] || die "project is $project, not $PROJECT"
DOMAIN=$(awk -F= '$1 == "DOMAIN" { print substr($0, index($0, "=") + 1); exit }' "$OVERRIDES")
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || die "no valid DOMAIN in $OVERRIDES"

status=0
pass() { echo "PASS $*"; }
miss() { echo "FAIL $*"; status=1; }

caddyfile() {
    cat <<EOF
$DOMAIN {
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
		health_uri /health
		health_interval 30s
		health_timeout 5s
		health_status 200
	}

	request_body {
		max_size 25MB
	}

	log {
		output stdout
		format console
		level INFO
	}
}
EOF
}

env_has_value() {
    [ -f "$ENV_FILE" ] &&
        awk -F= -v key="$1" '$1 == key && length(substr($0, index($0, "=") + 1)) > 0 { found = 1 } END { exit !found }' "$ENV_FILE"
}

if [ "$MODE" = --apply ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg jq postgresql-client python3
    install -m 0755 -d /etc/apt/keyrings
    if ! command -v gcloud >/dev/null || ! command -v docker-credential-gcloud >/dev/null; then
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg |
            gpg --dearmor --yes -o /etc/apt/keyrings/cloud.google.gpg
        echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
            > /etc/apt/sources.list.d/google-cloud-sdk.list
        apt-get update
        apt-get install -y google-cloud-cli
    fi
    if ! command -v docker >/dev/null; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
            gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io
    fi
    if ! command -v caddy >/dev/null; then
        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
            gpg --dearmor --yes -o /etc/apt/keyrings/caddy-stable.gpg
        echo "deb [signed-by=/etc/apt/keyrings/caddy-stable.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update
        apt-get install -y caddy
    fi

    gcloud auth configure-docker "$REGISTRY" --quiet
    systemctl enable --now docker

    install -d -m 0755 "$DATA_MOUNT"
    device_layout=$(lsblk -nr -o TYPE "$DATA_DEV" 2>/dev/null) || die "cannot inspect expected data device $DATA_DEV"
    [ "$device_layout" = disk ] || die "$DATA_DEV is not one unpartitioned block disk (layout: ${device_layout:-unknown})"
    mounted_at=$(lsblk -dn -o MOUNTPOINTS "$DATA_DEV" 2>/dev/null) ||
        die "cannot determine whether $DATA_DEV is mounted"
    mounted_at=$(printf '%s\n' "$mounted_at" | awk 'NF { print }')
    [ -z "$mounted_at" ] || [ "$mounted_at" = "$DATA_MOUNT" ] ||
        die "$DATA_DEV is already mounted at $mounted_at, not $DATA_MOUNT"
    fs_type=$(lsblk -dn -o FSTYPE "$DATA_DEV" 2>/dev/null) || die "cannot read the filesystem type of $DATA_DEV"
    signatures=$(wipefs -n --noheadings -o TYPE "$DATA_DEV" 2>/dev/null) ||
        die "cannot prove the existing signatures on $DATA_DEV"
    if [ -z "$fs_type" ]; then
        [ -z "${signatures//[[:space:]]/}" ] ||
            die "$DATA_DEV has an unrecognized existing signature; refusing to format"
        [ "$FORMAT_DATA_DISK" = 1 ] ||
            die "$DATA_DEV is verified blank; rerun once with --apply --format-data-disk to authorize mkfs"
        [ -z "$mounted_at" ] || die "$DATA_DEV is mounted; refusing to format"
        mkfs.ext4 "$DATA_DEV"
        fs_type=ext4
    fi
    [ "$fs_type" = ext4 ] || die "$DATA_DEV contains $fs_type, not ext4; refusing to format or mount"
    unexpected_signatures=$(printf '%s\n' "$signatures" | awk 'NF && $1 != "ext4" { print }')
    [ -z "$unexpected_signatures" ] || die "$DATA_DEV has signatures in addition to ext4; refusing to mount"
    fstab_entries=$(awk -v dev="$DATA_DEV" '$1 == dev { print }' /etc/fstab)
    if [ -n "$fstab_entries" ]; then
        [ "$fstab_entries" = "$DATA_DEV $DATA_MOUNT ext4 noatime,discard 0 2" ] ||
            die "$DATA_DEV has a conflicting /etc/fstab entry; refusing to append another"
    else
        echo "$DATA_DEV $DATA_MOUNT ext4 noatime,discard 0 2" >> /etc/fstab
    fi
    if mountpoint -q "$DATA_MOUNT"; then
        [ "$mounted_at" = "$DATA_MOUNT" ] || die "$DATA_MOUNT is occupied by another filesystem"
    else
        mount "$DATA_MOUNT"
    fi

    # docs/operations/coordinator-deploy.md step 3: the refresh script, the
    # manifests and, the first time on a host, the boot unit.
    install -d -m 0755 "$ENVLIB"
    install -m 0755 "$PROD/refresh-env.sh" "$REFRESH_BIN"
    install -m 0644 "$PROD/required-env-keys.txt" "$ENVLIB/required-env-keys.txt"
    install -m 0644 "$PROD/release-env-defaults" "$ENVLIB/release-env-defaults"
    install -m 0644 "$PROD/darkbloom-env-refresh.service" "$UNIT"
    systemctl daemon-reload
    systemctl enable darkbloom-env-refresh.service

    # A reload reconnects every provider, so it runs only when a running Caddy
    # must read a changed Caddyfile.
    caddyfile_changed=0
    if ! cmp -s <(caddyfile) "$CADDYFILE"; then
        install -d -m 0755 "$(dirname "$CADDYFILE")"
        caddyfile > "$CADDYFILE.new"
        caddy validate --adapter caddyfile --config "$CADDYFILE.new"
        mv -f "$CADDYFILE.new" "$CADDYFILE"
        caddyfile_changed=1
    fi
    caddy_was_active=0
    if systemctl is-active --quiet caddy; then caddy_was_active=1; fi
    systemctl enable --now caddy
    if [ "$caddyfile_changed" = 1 ] && [ "$caddy_was_active" = 1 ]; then
        systemctl reload caddy
    fi

    if env_has_value DD_API_KEY; then
        if ! dpkg -s datadog-agent >/dev/null 2>&1; then
            dd_key=$(awk -F= '$1 == "DD_API_KEY" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")
            dd_site=$(awk -F= '$1 == "DD_SITE" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")
            DD_API_KEY="$dd_key" DD_SITE="${dd_site:-datadoghq.com}" DD_ENV=development \
                bash -c "$(curl -fsSL https://install.datadoghq.com/scripts/install_script_agent7.sh)"
            unset dd_key
        fi
        if dpkg -s datadog-agent >/dev/null 2>&1; then
            systemctl enable datadog-agent
            systemctl restart datadog-agent
        fi
    fi
    echo "host setup: --apply done; the checks follow"
fi

for cmd in docker caddy gcloud docker-credential-gcloud jq psql pg_isready python3 findmnt lsblk wipefs; do
    if command -v "$cmd" >/dev/null; then pass "command $cmd"; else miss "command $cmd is missing. Fix: host-setup.sh --apply"; fi
done
for svc in docker caddy; do
    if systemctl is-active --quiet "$svc" && systemctl is-enabled --quiet "$svc"; then
        pass "service $svc is active and enabled"
    else
        miss "service $svc is not active and enabled. Fix: host-setup.sh --apply"
    fi
done
if [ -f /root/.docker/config.json ] && jq -e --arg r "$REGISTRY" '.credHelpers[$r] == "gcloud"' /root/.docker/config.json >/dev/null 2>&1; then
    pass "Docker uses gcloud credentials for $REGISTRY"
else
    miss "Docker has no gcloud credentials for $REGISTRY. Fix: host-setup.sh --apply"
fi
if [ "$(findmnt -n -o FSTYPE --target "$DATA_MOUNT" 2>/dev/null)" = ext4 ] && mountpoint -q "$DATA_MOUNT"; then
    pass "data disk is mounted at $DATA_MOUNT (ext4)"
else
    miss "data disk is not mounted at $DATA_MOUNT. Fix: host-setup.sh --apply"
fi
if grep -q "^$DATA_DEV $DATA_MOUNT " /etc/fstab 2>/dev/null; then pass "data disk is in /etc/fstab"; else miss "data disk is not in /etc/fstab. Fix: host-setup.sh --apply"; fi
if [ "$(findmnt -n -o FSTYPE --target /etc/d-inference 2>/dev/null || findmnt -n -o FSTYPE --target /etc)" != tmpfs ]; then
    pass "/etc/d-inference is on a persistent file system"
else
    miss "/etc/d-inference is tmpfs. Fix: move it to the boot disk"
fi
for pair in "refresh-env.sh:$REFRESH_BIN" "required-env-keys.txt:$ENVLIB/required-env-keys.txt" \
    "release-env-defaults:$ENVLIB/release-env-defaults" "darkbloom-env-refresh.service:$UNIT"; do
    if cmp -s "$PROD/${pair%%:*}" "${pair#*:}"; then
        pass "${pair#*:} is the copy of deploy/gcp/prod/${pair%%:*}"
    else
        miss "${pair#*:} is missing or differs from deploy/gcp/prod/${pair%%:*}. Fix: host-setup.sh --apply"
    fi
done
if systemctl is-enabled --quiet darkbloom-env-refresh.service; then
    pass "darkbloom-env-refresh.service is enabled"
else
    miss "darkbloom-env-refresh.service is not enabled. Fix: host-setup.sh --apply"
fi
if cmp -s <(caddyfile) "$CADDYFILE"; then
    pass "$CADDYFILE serves $DOMAIN"
else
    miss "$CADDYFILE is missing or differs from the expected file for $DOMAIN. Fix: host-setup.sh --apply"
fi
if env_has_value DD_API_KEY; then
    if systemctl is-active --quiet datadog-agent; then
        pass "Datadog Agent is active"
    else
        miss "DD_API_KEY is set but the Datadog Agent is not active. Fix: host-setup.sh --apply"
    fi
else
    echo "REPORT DD_API_KEY is not set in $ENV_FILE (or the file is absent); no Datadog Agent"
fi
exit "$status"
