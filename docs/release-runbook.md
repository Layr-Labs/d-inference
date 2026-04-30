# EigenInference Release Runbook

How to build, release, and distribute provider binaries. Covers both the automated GitHub Actions pipeline and manual release process.

## Architecture

```
GitHub Actions (on v* tag)          R2 CDN (binary hosting)           Coordinator (metadata)
┌──────────────────────┐           ├── releases/                     ├── Release table (Postgres)
│ Build provider (Rust)│──upload──>│   ├── v0.2.1/                   │   version, hash, URL, active
│ Build enclave (Swift)│           │   │   └── bundle.tar.gz         │
│ Run tests            │           │   └── v0.2.0/                   ├── POST /v1/releases
│ Create bundle tarball│           │       └── bundle.tar.gz         │   (scoped release key)
│ Compute SHA-256      │           └── models/ (existing)            │
│ Upload to R2         │                                             ├── GET /v1/releases/latest
│ Register with coord  │──POST───────────────────────────────────────│   (public, install.sh)
│ Create GitHub Release│                                             │
└──────────────────────┘                                             └── auto-updates known hashes
```

## Automated Release (recommended)

Tag and push — everything else is automated.

### 1. Bump versions

Update the version in two places:

```bash
# provider/Cargo.toml line 3
version = "0.2.1"

# coordinator/internal/api/server.go line 57
var LatestProviderVersion = "0.2.1"
```

### 2. Commit and tag

```bash
git add provider/Cargo.toml coordinator/internal/api/server.go
git commit -m "Bump provider version to 0.2.1"
git tag v0.2.1
git push origin master --tags
```

### 3. GitHub Action runs automatically

The `.github/workflows/release.yml` workflow:

1. Builds `darkbloom` (Rust, `--no-default-features`)
2. Builds `eigeninference-enclave` (Swift)
3. Runs all tests (provider + coordinator)
4. Creates code-signed bundle tarball
5. Computes SHA-256 of binary and bundle
6. Uploads bundle to R2 at `releases/v0.2.1/eigeninference-bundle-macos-arm64.tar.gz`
7. Registers the release with coordinator via `POST /v1/releases` (scoped key)
8. Creates a GitHub Release with the bundle attached

### 4. Verify

```bash
# Check the release was registered
./scripts/admin.sh releases latest

# Check GitHub Release
gh release view v0.2.1

# Check a fresh install works
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

## Manual Release (fallback)

If GitHub Actions is down or you need to release from your local machine.

### 1. Build

```bash
# Provider
cd provider
cargo build --release --no-default-features

# Enclave
cd ../enclave
swift build -c release
```

### 2. Create bundle

```bash
mkdir -p /tmp/eigeninference-bundle
cp provider/target/release/darkbloom /tmp/eigeninference-bundle/
cp enclave/.build/release/eigeninference-enclave /tmp/eigeninference-bundle/

# Code sign
codesign --force --sign - --entitlements scripts/entitlements.plist \
  --options runtime /tmp/eigeninference-bundle/darkbloom
codesign --force --sign - --entitlements scripts/entitlements.plist \
  --options runtime /tmp/eigeninference-bundle/eigeninference-enclave

cd /tmp && tar czf eigeninference-bundle-macos-arm64.tar.gz -C eigeninference-bundle .
```

### 3. Compute hashes

```bash
BINARY_HASH=$(shasum -a 256 provider/target/release/darkbloom | cut -d' ' -f1)
BUNDLE_HASH=$(shasum -a 256 /tmp/eigeninference-bundle-macos-arm64.tar.gz | cut -d' ' -f1)
echo "Binary: $BINARY_HASH"
echo "Bundle: $BUNDLE_HASH"
```

### 4. Upload to R2

```bash
VERSION="0.2.1"
aws s3 cp /tmp/eigeninference-bundle-macos-arm64.tar.gz \
  "s3://d-inf-releases/releases/v${VERSION}/eigeninference-bundle-macos-arm64.tar.gz" \
  --endpoint-url "$R2_ENDPOINT"
```

### 5. Register with coordinator

```bash
VERSION="0.2.1"
R2_PUBLIC_URL="https://pub-XXXX.r2.dev"

curl -X POST https://api.darkbloom.dev/v1/releases \
  -H "Authorization: Bearer $EIGENINFERENCE_RELEASE_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"version\": \"$VERSION\",
    \"platform\": \"macos-arm64\",
    \"binary_hash\": \"$BINARY_HASH\",
    \"bundle_hash\": \"$BUNDLE_HASH\",
    \"url\": \"$R2_PUBLIC_URL/releases/v$VERSION/eigeninference-bundle-macos-arm64.tar.gz\"
  }"
```

Or using the admin script with the full bundle script:

```bash
./scripts/build-bundle.sh --release
```

## Managing Releases

### List all releases

```bash
./scripts/admin.sh releases list
```

### Check latest active release

```bash
./scripts/admin.sh releases latest
# or: curl https://api.darkbloom.dev/v1/releases/latest?platform=macos-arm64
```

### Deactivate an old version

Providers running this version will be marked untrusted on their next challenge response (within 3 minutes).

```bash
./scripts/admin.sh releases deactivate 0.2.0
```

### Rollback

To rollback to a previous version, deactivate the bad version. The old version is still in R2 and still active in the coordinator, so `install.sh` will automatically serve it as the latest.

```bash
# Deactivate the broken release
./scripts/admin.sh releases deactivate 0.2.1

# Verify latest is now the previous version
./scripts/admin.sh releases latest
```

## Auth & Credentials

### Release key (GitHub Action)

| Item | Details |
|------|---------|
| Env var (coordinator) | `EIGENINFERENCE_RELEASE_KEY` |
| GitHub Secret | `EIGENINFERENCE_RELEASE_KEY` |
| Scope | Can only `POST /v1/releases` — no admin access |
| If leaked | Release registration still requires the URL to match `EIGENINFERENCE_R2_CDN_URL` and the coordinator verifies the downloaded bundle hash plus bundled `bin/darkbloom` hash before whitelisting it. Treat leakage as serious, but the key alone should not be enough to whitelist an arbitrary provider binary unless the release artifact origin is also compromised. |

### Admin access (managing releases)

| Method | When to use |
|--------|-------------|
| `EIGENINFERENCE_ADMIN_KEY` | Pre-production, dev, quick ops |
| Privy email OTP | Production — `./scripts/admin.sh login` |

### Required GitHub Secrets

| Secret | Purpose |
|--------|---------|
| `EIGENINFERENCE_RELEASE_KEY` | Scoped key for registering releases |
| `COORDINATOR_URL` | Coordinator API URL |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret key |
| `R2_ENDPOINT` | R2 S3-compatible endpoint URL |
| `R2_PUBLIC_URL` | Public R2 CDN URL for download links |

## How Binary Verification Works

1. **At build time**: SHA-256 of `darkbloom` binary is computed
2. **At release registration**: coordinator downloads the R2 bundle, verifies `bundle_hash`, extracts `bin/darkbloom`, and verifies `binary_hash` before storing the release
3. **At startup and release changes**: `SyncBinaryHashes()` loads all active release hashes and preserves additive env/manual hashes in `knownBinaryHashes`
4. **At provider registration**: attestation blob must contain `binaryHash` → checked against known set; Open Mode is rejected when a binary hash policy is configured
5. **At every challenge** (every 3 min): provider re-computes its binary hash → challenge signature must verify against the attested Secure Enclave key → hash must still match the signed registration attestation and known set
6. **Missing or unknown hash**: provider's attestation/challenge is rejected and the provider is marked untrusted

## How Install Verification Works

1. `install.sh` calls `GET /v1/releases/latest?platform=macos-arm64`
2. Gets back `{ version, bundle_hash, url }`
3. Downloads bundle from R2 URL
4. Computes `shasum -a 256` of downloaded file
5. Compares against `bundle_hash` — refuses to install if mismatch
6. Falls back to legacy coordinator download if release API is unavailable

## Checklist

Before releasing:

- [ ] All tests pass locally (`cd coordinator && go test ./...` + `cd provider && cargo test`)
- [ ] Pre-push hook passes (`git push` runs tests automatically)
- [ ] Version bumped in `Cargo.toml` and `server.go`
- [ ] No secrets in the commit (`git diff --cached | grep -i secret`)
- [ ] Tag matches version (`v0.2.1` for version `0.2.1`)

After releasing:

- [ ] GitHub Action completed successfully
- [ ] `./scripts/admin.sh releases latest` shows new version
- [ ] Fresh `install.sh` run downloads and verifies the new bundle
- [ ] Existing providers pick up the new version on next update check
