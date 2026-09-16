#!/bin/bash
# Install and configure the Datadog Agent on the production coordinator host.
#
# HUMAN-ONLY. This mutates the production VM, which CLAUDE.md reserves for
# humans; an agent may prepare and review it but must not run it.
#
# Why a host agent at all: the coordinator hands every counter, gauge and
# histogram to DogStatsD and owns nothing after that — no aggregation, no
# batching, no retries. On a host with no agent those datagrams go nowhere,
# which is what production did for as long as it did. Runbook, including the
# mandatory ordering against the image deploy:
# docs/operations/datadog-agent.md
#
# Prod runs the coordinator container with --network host, so a host-level agent
# is reachable on localhost:8125 (DogStatsD) and localhost:8126 (APM) with no
# container, port or mount change, and without dogstatsd_non_local_traffic.
#
# Scope is metrics and traces. Log delivery stays on the coordinator's own Logs
# API path: it carries provider-sourced telemetry that never appears in this
# host's container logs, and its allowlist is the privacy backstop
# (coordinator/api/telemetry_handlers.go). Turning on the agent's Docker log
# collection would be a second, duplicate stream with its own bill — a separate
# decision, deliberately not made here.
#
# Usage (on the prod VM, as root):
#   ./install-datadog-agent.sh --check    # report only, no writes
#   ./install-datadog-agent.sh --apply    # install, configure, restart, verify
#
# Idempotent in what it installs and writes: re-running --apply reinstalls
# nothing and rewrites the config only when it differs. It does still restart the
# agent every time, which briefly interrupts this host's metric path — so a
# no-op run is not free, and --check is the way to look without touching.
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/d-inference/env}
DD_CONF_DIR=${DD_CONF_DIR:-/etc/datadog-agent}
DD_CONF_FILE="$DD_CONF_DIR/datadog.yaml"
# The GCE instance name, so the host lines up with the VM an operator would look
# at. Metrics are scoped by the env/service tags, not by host.
AGENT_HOSTNAME=${AGENT_HOSTNAME:-darkbloom-coordinator}
INSTALL_SCRIPT_URL=${INSTALL_SCRIPT_URL:-https://s3.amazonaws.com/dd-agent/scripts/install_script_agent7.sh}
DOGSTATSD_PORT=${DOGSTATSD_PORT:-8125}
MODE=${1:---check}

fail() {
    echo "datadog agent install: $*" >&2
    exit 1
}

note() { echo "datadog agent install: $*"; }

case "$MODE" in
    --check | --apply) ;;
    *) fail "usage: $0 [--check|--apply]" ;;
esac

[ -r "$ENV_FILE" ] || fail "cannot read $ENV_FILE (run as root on the coordinator host)"

# env_value reads one key out of the coordinator's env file. tail -n1 mirrors
# what the container would see if a key were somehow duplicated: last wins. The
# trailing CR is stripped because a file that ever passed through a CRLF editor
# would otherwise hand the agent a key one invisible byte too long, which fails
# authentication while every echo of it looks correct.
env_value() {
    awk -F= -v key="$1" '$1 == key { v = substr($0, index($0, "=") + 1); sub(/\r$/, "", v); print v }' "$ENV_FILE" | tail -n1
}

DD_API_KEY_VAL=$(env_value DD_API_KEY)
DD_SITE_VAL=$(env_value DD_SITE)
[ -n "$DD_SITE_VAL" ] || DD_SITE_VAL=datadoghq.com

# Never echoed, only length-checked: this is the same key the coordinator uses
# for the Logs API, and it is the one thing in this script that must not reach a
# terminal or a log.
[ -n "$DD_API_KEY_VAL" ] ||
    fail "DD_API_KEY is missing or empty in $ENV_FILE; the agent has nothing to authenticate with"
note "using DD_API_KEY from $ENV_FILE (${#DD_API_KEY_VAL} chars), site=$DD_SITE_VAL"

for key in DD_ENV DD_SERVICE DD_AGENT_HOST; do
    value=$(env_value "$key")
    if [ -z "$value" ]; then
        note "WARNING: $key is not set in $ENV_FILE — run deploy/gcp/prod/refresh-env.sh --apply first"
        note "         (release-env-defaults supplies it; without it the coordinator tags metrics with code defaults)"
    else
        note "$key=$value"
    fi
done

# The agent's own env/service tags come from the same file the coordinator reads,
# not from a second constant in this script: host metrics tagged env:production
# while the coordinator tagged env:staging would split every dashboard by a
# difference no operator would think to look for.
AGENT_ENV=${AGENT_ENV:-$(env_value DD_ENV)}
[ -n "$AGENT_ENV" ] || AGENT_ENV=production
PROBE_SERVICE=$(env_value DD_SERVICE)
[ -n "$PROBE_SERVICE" ] || PROBE_SERVICE=d-inference-coordinator

# dpkg -l exits 0 for a removed-but-not-purged package (state `rc`), which would
# skip the install and surface later as a confusing "could not enable
# datadog-agent.service"; the Status field is the only reliable answer.
agent_installed() {
    command -v datadog-agent >/dev/null 2>&1 && return 0
    dpkg-query -W -f='${Status}' datadog-agent 2>/dev/null | grep -q 'install ok installed'
}

# The config the agent should end up with. dogstatsd_socket and receiver_socket
# are explicitly empty: UDS would need a bind mount into the container, and the
# container already shares the host's network namespace, so UDP localhost is
# sufficient. Dev uses the same UDP transport (deploy/gcp/vm-startup.sh) but not
# the same config: it also enables log collection and orders the agent ahead of
# the coordinator with After=/Wants=, neither of which prod can do.
#
# api_key is quoted: a trailing CR from an editor-touched env file would
# otherwise land in the config as part of the key and fail authentication with
# no visible cause.
render_config() {
    cat <<DDYAML
# Managed by deploy/gcp/prod/install-datadog-agent.sh. Hand edits are preserved
# only as a timestamped .bak; re-running --apply overwrites this file.
api_key: "${DD_API_KEY_VAL}"
site: ${DD_SITE_VAL}
env: ${AGENT_ENV}
hostname: ${AGENT_HOSTNAME}
dogstatsd_port: ${DOGSTATSD_PORT}

# The coordinator forwards its own logs to the Logs API; see the header.
logs_enabled: false

apm_config:
  enabled: true
  receiver_socket: ""
dogstatsd_socket: ""
DDYAML
}

config_matches() {
    [ -r "$DD_CONF_FILE" ] || return 1
    render_config | diff -q - "$DD_CONF_FILE" >/dev/null 2>&1
}

# agent_status captures the agent's status once. `|| true` is load-bearing
# everywhere this output is used: `datadog-agent status` exits non-zero whenever
# its IPC port is not answering yet, and under `set -euo pipefail` an assignment
# from a failing pipeline aborts the script — which would kill this runbook at
# its verification step, after the config was rewritten and the agent restarted,
# with no message and no "deploy only after this point" line.
agent_status() {
    datadog-agent status 2>/dev/null || true
}

# dogstatsd_metric_packets reads the agent's own received-packet counter. It is
# the only local evidence that a datagram sent to 8125 was actually accepted
# rather than dropped by a kernel with nothing bound. No `exit` after the match:
# awk closing the pipe early makes a long status output die of SIGPIPE, which
# pipefail would then turn into an abort.
dogstatsd_metric_packets() {
    printf '%s\n' "$1" | awk -F: '/Metric Packets:/ && !seen { gsub(/[^0-9]/, "", $2); print $2; seen = 1 }'
}

# api_key_state answers whether the agent could authenticate the key it was just
# handed. Accepting a datagram on 8125 proves only that the listener is up; a
# rotated or truncated key passes that gate and still delivers nothing to
# Datadog, which is the same silent-loss class this whole change exists to end —
# just moved one hop downstream. "invalid" is matched first because it contains
# "valid" as a substring.
api_key_state() {
    printf '%s\n' "$1" | awk '
        /API [Kk]ey/ && /[Ii]nvalid/ { print "invalid"; found = 1; exit }
        /API [Kk]ey/ && /[Vv]alid/   { print "valid";   found = 1; exit }
        END { if (!found) print "unknown" }'
}

# forwarder_successes is the count of payloads the agent got accepted upstream.
forwarder_successes() {
    printf '%s\n' "$1" | awk -F: '/^[[:space:]]*Success(es)?:/ && !seen { gsub(/[^0-9]/, "", $2); print $2; seen = 1 }'
}

if [ "$MODE" = "--check" ]; then
    if agent_installed; then
        note "agent is installed: $(datadog-agent version 2>/dev/null || echo 'version unavailable')"
    else
        note "agent is NOT installed; --apply would fetch $INSTALL_SCRIPT_URL"
    fi
    if config_matches; then
        note "$DD_CONF_FILE already matches the desired config"
    elif [ -r "$DD_CONF_FILE" ]; then
        # Both sides are redacted before comparison, so an empty diff here means
        # the api_key is the only thing that changed — worth saying out loud
        # rather than printing nothing under a "differs" heading.
        redacted_diff=$(diff -u \
            <(sed 's/^api_key:.*/api_key: <redacted>/' "$DD_CONF_FILE") \
            <(render_config | sed 's/^api_key:.*/api_key: <redacted>/') || true)
        if [ -n "$redacted_diff" ]; then
            note "$DD_CONF_FILE differs; --apply would rewrite it (api_key redacted):"
            printf '%s\n' "$redacted_diff"
        else
            note "$DD_CONF_FILE differs only in api_key; --apply would rewrite it"
        fi
    else
        note "$DD_CONF_FILE does not exist; --apply would create it"
    fi
    if systemctl is-active --quiet datadog-agent 2>/dev/null; then
        status_out=$(agent_status)
        packets=$(dogstatsd_metric_packets "$status_out")
        [ -n "$packets" ] || packets="unavailable"
        # A single reading is a cumulative total, not evidence of traffic: it
        # takes two runs to see it climb.
        note "datadog-agent.service is active; DogStatsD metric packets received since agent start: $packets"
        note "API key: $(api_key_state "$status_out")"
    else
        note "datadog-agent.service is not active"
    fi
    exit 0
fi

# ---- apply ----

if agent_installed; then
    note "agent already installed, skipping install script"
else
    note "installing the Datadog Agent 7"
    DD_API_KEY="$DD_API_KEY_VAL" DD_SITE="$DD_SITE_VAL" \
        DD_INSTALL_ONLY=true \
        bash -c "$(curl -fsSL "$INSTALL_SCRIPT_URL")" ||
        fail "agent install failed"
fi
agent_installed || fail "agent still not present after install"

if config_matches; then
    note "$DD_CONF_FILE already current"
else
    mkdir -p "$DD_CONF_DIR"
    if [ -f "$DD_CONF_FILE" ]; then
        backup="$DD_CONF_FILE.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        cp -p "$DD_CONF_FILE" "$backup"
        # The backup contains the API key in plaintext, so it is narrowed to
        # root-only rather than left at the config's 0640 root:dd-agent. These
        # accumulate; the runbook's rollback section says when they can go.
        chmod 0600 "$backup"
        note "backed up existing config to $backup (contains the API key; root-only)"
    fi
    tmp=$(mktemp "$DD_CONF_DIR/.datadog.yaml.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    render_config > "$tmp"
    chmod 0640 "$tmp"
    # The agent runs as dd-agent and refuses to start on a config it cannot
    # read; the install script creates the user before this point.
    chown dd-agent:dd-agent "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DD_CONF_FILE"
    trap - EXIT
    note "wrote $DD_CONF_FILE"
fi

# enable, not just restart: the coordinator container runs under
# `--restart unless-stopped` with no systemd unit, so nothing on this host
# orders the agent before it. That is tolerable at steady state — DogStatsD is
# stateless UDP and the coordinator recovers the moment the agent answers, and
# it now logs while it does not — but the agent must survive a reboot on its own.
systemctl enable datadog-agent.service >/dev/null 2>&1 || fail "could not enable datadog-agent.service"
systemctl restart datadog-agent.service || fail "could not start datadog-agent.service"

# `systemctl is-active` goes true within milliseconds of the restart, seconds
# before the agent's IPC port answers, so waiting on it alone would leave every
# reader below racing the agent's startup. Wait for `status` itself to answer.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    systemctl is-active --quiet datadog-agent &&
        datadog-agent status >/dev/null 2>&1 && break
    sleep 2
done
systemctl is-active --quiet datadog-agent || fail "datadog-agent.service is not active after restart"
datadog-agent status >/dev/null 2>&1 ||
    fail "datadog-agent.service is active but 'datadog-agent status' does not answer; check journalctl -u datadog-agent"
note "datadog-agent.service is active and answering status"

# Prove the socket accepts traffic rather than assuming it. Opening and writing
# a UDP socket succeeds whether or not anything is listening — that is the whole
# reason this failure went unnoticed in the first place — so the evidence has to
# come from the agent's own counter, not from the send. The probe itself is one
# throwaway custom metric.
status_before=$(agent_status)
before=$(dogstatsd_metric_packets "$status_before")
[ -n "$before" ] || before=0
sent_before=$(forwarder_successes "$status_before")
[ -n "$sent_before" ] || sent_before=0

probe="d_inference.deploy.agent_install_probe:1|c|#env:${AGENT_ENV},service:${PROBE_SERVICE}"
if ! (exec 3<>"/dev/udp/127.0.0.1/${DOGSTATSD_PORT}" && printf '%s\n' "$probe" >&3 && exec 3>&-); then
    fail "could not open a UDP socket to 127.0.0.1:${DOGSTATSD_PORT}"
fi
# DogStatsD's stats are refreshed on the agent's flush interval (~10 s); 15 s
# leaves room for one full window plus the forwarder's round trip.
sleep 15

status_after=$(agent_status)
after=$(dogstatsd_metric_packets "$status_after")
[ -n "$after" ] || after=0
if [ "$after" -le "$before" ]; then
    fail "DogStatsD metric packets did not advance ($before -> $after); check 'datadog-agent status'"
fi
note "DogStatsD is receiving: metric packets $before -> $after"

# Half the guarantee. The listener accepting a datagram says nothing about
# whether the agent can authenticate and ship it, so check the key and the
# forwarder too.
case "$(api_key_state "$status_after")" in
    invalid)
        fail "the agent rejected DD_API_KEY as invalid; metrics will be accepted locally and dropped upstream. Fix the key in $ENV_FILE and re-run --apply"
        ;;
    valid) note "API key validated by the agent" ;;
    *)
        note "WARNING: could not determine API key validity from 'datadog-agent status'"
        note "         check its 'API Keys status' section by hand before deploying the image"
        ;;
esac

sent_after=$(forwarder_successes "$status_after")
[ -n "$sent_after" ] || sent_after=0
if [ "$sent_after" -gt "$sent_before" ]; then
    note "forwarder is delivering: successful transactions $sent_before -> $sent_after"
else
    # Not fatal: the forwarder's counters and section names have moved between
    # agent versions, and a false abort here strands a human mid-runbook with a
    # freshly restarted agent. Loud enough to be acted on instead.
    note "WARNING: forwarder successes did not advance ($sent_before -> $sent_after)"
    note "         confirm the metric in Datadog before deploying: d_inference.deploy.agent_install_probe{env:${AGENT_ENV}}"
fi

note "done. Deploy the coordinator image only AFTER this point — see docs/operations/datadog-agent.md"
