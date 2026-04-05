# EigenInference Deploy Runbook

How to build, deploy, and update all EigenInference components: the coordinator, provider CLI, and macOS app bundle.

## Infrastructure

| Item | Value |
|------|-------|
| Instance | `eigeninference-mdm` (`i-01a3a5368995a99aa`) |
| Type | `t3.small` (us-east-1a) |
| Public IP | `34.197.17.112` (Elastic IP) |
| Domain | `inference-test.openinnovation.dev` |
| SSH Key | `~/.ssh/eigeninference-infra` |
| SSH User | `ubuntu` |
| AWS Profile | `admin` |
| Binary Path | `/usr/local/bin/eigeninference-coordinator` |
| Service | `eigeninference-coordinator.service` (systemd) |
| Listens on | `:8080` (proxied by nginx on 443) |

## Environment Variables (set in systemd unit)

- `EIGENINFERENCE_PORT=8080`
- `EIGENINFERENCE_ADMIN_KEY=eigeninference-admin-key-2026`
- `EIGENINFERENCE_MDM_URL=https://inference-test.openinnovation.dev`
- `EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api`

## Deploy Steps

### 1. Build the Linux binary

From the repo root:

```bash
cd coordinator
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o eigeninference-coordinator-linux ./cmd/coordinator
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
scp -i ~/.ssh/eigeninference-infra eigeninference-coordinator-linux ubuntu@34.197.17.112:/tmp/eigeninference-coordinator
```

### 4. SSH in and swap the binary

```bash
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112
```

On the server:

```bash
# Stop the service
sudo systemctl stop eigeninference-coordinator

# Replace the binary
sudo mv /tmp/eigeninference-coordinator /usr/local/bin/eigeninference-coordinator
sudo chmod +x /usr/local/bin/eigeninference-coordinator

# Start the service
sudo systemctl start eigeninference-coordinator

# Verify it's running
sudo systemctl status eigeninference-coordinator
sudo journalctl -u eigeninference-coordinator -n 20 --no-pager
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
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o eigeninference-coordinator-linux ./cmd/coordinator && \
scp -i ~/.ssh/eigeninference-infra eigeninference-coordinator-linux ubuntu@34.197.17.112:/tmp/eigeninference-coordinator && \
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop eigeninference-coordinator && \
   sudo mv /tmp/eigeninference-coordinator /usr/local/bin/eigeninference-coordinator && \
   sudo chmod +x /usr/local/bin/eigeninference-coordinator && \
   sudo systemctl start eigeninference-coordinator && \
   sleep 2 && \
   sudo systemctl status eigeninference-coordinator --no-pager'
```

## Rollback

If the new binary fails to start:

```bash
# The previous binary isn't kept automatically. If you need rollback,
# keep a copy before deploying:
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo cp /usr/local/bin/eigeninference-coordinator /usr/local/bin/eigeninference-coordinator.bak'
```

To rollback:

```bash
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop eigeninference-coordinator && \
   sudo mv /usr/local/bin/eigeninference-coordinator.bak /usr/local/bin/eigeninference-coordinator && \
   sudo systemctl start eigeninference-coordinator'
```

## Other services on this machine

- **nginx** — TLS termination and reverse proxy (443 → 8080). Config at `/etc/nginx/sites-enabled/eigeninference-mdm`.
- **MicroMDM** — Apple MDM server on port 9002 (`micromdm.service`). Used for device attestation.
- **step-ca** — ACME server for device certificate issuance (`step-ca.service`).
- **Let's Encrypt** — TLS certs at `/etc/letsencrypt/live/inference-test.openinnovation.dev/`.

## Troubleshooting

**Port 8080 already in use**: An old coordinator process is still running. Kill it manually:

```bash
sudo kill $(sudo lsof -ti :8080)
sudo systemctl start eigeninference-coordinator
```

**Service crash-looping**: Check logs:

```bash
sudo journalctl -u eigeninference-coordinator -n 50 --no-pager
```

**WebSocket disconnects**: The nginx config has `proxy_read_timeout 86400` (24h) for `/ws/`. If providers are disconnecting frequently, check nginx error logs:

```bash
sudo tail -50 /var/log/nginx/error.log
```

---

## Provider CLI & Bundle Distribution

Providers install via a curl one-liner that downloads a tarball from the coordinator server:

```bash
curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
```

This downloads `eigeninference-bundle-macos-arm64.tar.gz` from `/var/www/html/dl/` on the server and extracts it to `~/.eigeninference/`.

### What's in the bundle

| File | Description |
|------|-------------|
| `eigeninference-provider` | Rust CLI binary (arm64 macOS) |
| `eigeninference-enclave` | Swift Secure Enclave attestation helper |
| `python/` | Standalone Python 3.12 + mlx + vllm-mlx |

### Building the provider CLI

```bash
cd provider
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release --no-default-features
```

The binary is at `target/release/eigeninference-provider`.

### Building the Secure Enclave helper

```bash
cd app/EigenInference
swift build -c release --product eigeninference-enclave
```

### Creating the tarball bundle

The tarball bundles the provider binary, enclave helper, and a standalone Python environment with mlx/vllm-mlx pre-installed.

Prerequisites:
- Python bundle already set up at `~/.eigeninference/python/` (created by a prior install or manual setup)
- Provider binary built (`cargo build --release --no-default-features`)
- Enclave binary built (`swift build -c release`)

```bash
# Create bundle directory
mkdir -p /tmp/eigeninference-bundle
cp provider/target/release/eigeninference-provider /tmp/eigeninference-bundle/
cp app/EigenInference/.build/release/eigeninference-enclave /tmp/eigeninference-bundle/
cp -a ~/.eigeninference/python /tmp/eigeninference-bundle/

# Create tarball
cd /tmp/eigeninference-bundle
tar czf eigeninference-bundle-macos-arm64.tar.gz eigeninference-provider eigeninference-enclave python/
```

### Uploading the bundle to the server

```bash
scp -i ~/.ssh/eigeninference-infra /tmp/eigeninference-bundle/eigeninference-bundle-macos-arm64.tar.gz \
  ubuntu@34.197.17.112:/tmp/

ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo mv /tmp/eigeninference-bundle-macos-arm64.tar.gz /var/www/html/dl/ && \
   ls -lh /var/www/html/dl/eigeninference-bundle-macos-arm64.tar.gz'
```

### Updating install.sh

The install script is at `scripts/install.sh` in the repo and served from `/var/www/html/install.sh` on the server. To update:

```bash
scp -i ~/.ssh/eigeninference-infra scripts/install.sh ubuntu@34.197.17.112:/tmp/ && \
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo mv /tmp/install.sh /var/www/html/install.sh'
```

### Verify the distribution

```bash
# Check tarball is accessible
curl -sI https://inference-test.openinnovation.dev/dl/eigeninference-bundle-macos-arm64.tar.gz | head -5

# Check install script is accessible
curl -s https://inference-test.openinnovation.dev/install.sh | head -5
```

---

## macOS App Bundle (.app / .dmg)

For distributing the full macOS menu bar app (not just the CLI).

### Build the app bundle

```bash
./scripts/bundle-app.sh                                      # Ad-hoc signing (testing only)
./scripts/bundle-app.sh "Developer ID Application: OrgName"  # Production signing
./scripts/bundle-app.sh "Developer ID Application: OrgName" --notarize  # + Apple notarization
```

This produces:
- `build/EigenInference.app` — Code-signed macOS app with hardened runtime
- `build/EigenInference-0.1.0.dmg` — Drag-and-drop installer DMG

The app bundle includes the provider binary, enclave helper, and bundled Python — all code-signed so any tampering breaks the signature.

### Prerequisites for the app bundle

```bash
# 1. Build the Rust provider (release, no Python feature to avoid linking issues)
cd provider && cargo build --release --no-default-features && cd ..

# 2. Build the Swift app and enclave helper
cd app/EigenInference && swift build -c release && cd ../..

# 3. Ensure Python bundle exists at ~/.eigeninference/python/
```

### Distributing the DMG

Currently manual — upload the DMG wherever you want to host it. The install.sh flow uses the tarball, not the DMG. The DMG is for users who prefer a traditional macOS app install.

---

## Server file layout

Files served by nginx from `/var/www/html/`:

```
/var/www/html/
├── index.html                          # Landing page
├── install.sh                          # curl installer script
├── enroll.mobileconfig                 # MDM enrollment profile
├── eigeninference-provider-macos-arm64.tar.gz   # Legacy standalone provider tarball
└── dl/
    ├── eigeninference-bundle-macos-arm64.tar.gz # Full bundle (provider + python + enclave)
    ├── eigeninference-provider                  # Standalone provider binary
    └── eigeninference-enclave                   # Standalone enclave binary
```
