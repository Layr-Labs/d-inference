# Coordinator Deploy Runbook

How to build, deploy, and update the DGInf coordinator running on AWS.

## Infrastructure

| Item | Value |
|------|-------|
| Instance | `dginf-mdm` (`i-01a3a5368995a99aa`) |
| Type | `t3.small` (us-east-1a) |
| Public IP | `34.197.17.112` (Elastic IP) |
| Domain | `inference-test.openinnovation.dev` |
| SSH Key | `~/.ssh/dginf-infra` |
| SSH User | `ubuntu` |
| AWS Profile | `admin` |
| Binary Path | `/usr/local/bin/dginf-coordinator` |
| Service | `dginf-coordinator.service` (systemd) |
| Listens on | `:8080` (proxied by nginx on 443) |

## Environment Variables (set in systemd unit)

- `DGINF_PORT=8080`
- `DGINF_ADMIN_KEY=dginf-admin-key-2026`
- `DGINF_MDM_URL=https://inference-test.openinnovation.dev`
- `DGINF_MDM_API_KEY=dginf-micromdm-api`

## Deploy Steps

### 1. Build the Linux binary

From the repo root:

```bash
cd coordinator
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator
```

This produces a statically linked amd64 binary.

### 2. Run tests before deploying

```bash
cd coordinator
go test ./...
```

All tests must pass before deploying.

### 3. Copy the binary to the server

```bash
scp -i ~/.ssh/dginf-infra dginf-coordinator-linux ubuntu@34.197.17.112:/tmp/dginf-coordinator
```

### 4. SSH in and swap the binary

```bash
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112
```

On the server:

```bash
# Stop the service
sudo systemctl stop dginf-coordinator

# Replace the binary
sudo mv /tmp/dginf-coordinator /usr/local/bin/dginf-coordinator
sudo chmod +x /usr/local/bin/dginf-coordinator

# Start the service
sudo systemctl start dginf-coordinator

# Verify it's running
sudo systemctl status dginf-coordinator
sudo journalctl -u dginf-coordinator -n 20 --no-pager
```

### 5. Verify the deployment

```bash
# Health check
curl https://inference-test.openinnovation.dev/health

# Models endpoint
curl https://inference-test.openinnovation.dev/v1/models
```

## Quick one-liner deploy

From the repo root (builds, copies, restarts in one shot):

```bash
cd coordinator && \
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator && \
scp -i ~/.ssh/dginf-infra dginf-coordinator-linux ubuntu@34.197.17.112:/tmp/dginf-coordinator && \
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop dginf-coordinator && \
   sudo mv /tmp/dginf-coordinator /usr/local/bin/dginf-coordinator && \
   sudo chmod +x /usr/local/bin/dginf-coordinator && \
   sudo systemctl start dginf-coordinator && \
   sleep 2 && \
   sudo systemctl status dginf-coordinator --no-pager'
```

## Rollback

If the new binary fails to start:

```bash
# The previous binary isn't kept automatically. If you need rollback,
# keep a copy before deploying:
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112 \
  'sudo cp /usr/local/bin/dginf-coordinator /usr/local/bin/dginf-coordinator.bak'
```

To rollback:

```bash
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop dginf-coordinator && \
   sudo mv /usr/local/bin/dginf-coordinator.bak /usr/local/bin/dginf-coordinator && \
   sudo systemctl start dginf-coordinator'
```

## Other services on this machine

- **nginx** — TLS termination and reverse proxy (443 → 8080). Config at `/etc/nginx/sites-enabled/dginf-mdm`.
- **MicroMDM** — Apple MDM server on port 9002 (`micromdm.service`). Used for device attestation.
- **step-ca** — ACME server for device certificate issuance (`step-ca.service`).
- **Let's Encrypt** — TLS certs at `/etc/letsencrypt/live/inference-test.openinnovation.dev/`.

## Troubleshooting

**Port 8080 already in use**: An old coordinator process is still running. Kill it manually:

```bash
sudo kill $(sudo lsof -ti :8080)
sudo systemctl start dginf-coordinator
```

**Service crash-looping**: Check logs:

```bash
sudo journalctl -u dginf-coordinator -n 50 --no-pager
```

**WebSocket disconnects**: The nginx config has `proxy_read_timeout 86400` (24h) for `/ws/`. If providers are disconnecting frequently, check nginx error logs:

```bash
sudo tail -50 /var/log/nginx/error.log
```
