# State Export Runbook (DAR-70)

How the admin-gated `/v1/admin/state-export` endpoint works end-to-end, and the exact operator flow to extract the TEE-sealed coordinator state and rehydrate it on a target machine (e.g. a GCP Confidential VM).

> **AI agents must NOT run this against prod.** Enabling the endpoint, deploying the export build, and running the extraction are **human-only** actions. This doc prepares the commands; a human executes them.

## What this solves

The prod coordinator's trust state is born inside the EigenCloud TEE and has never left it:

- `/data/micromdm/` — the MicroMDM BoltDB (the enrolled-device database that the hardware-trust check reads against), plus the push cert and the `.push_imported` sentinel. **This is the state that matters.**
- `/data/step-ca/` — legacy: the CA keys of the former ACME `device-attest-01` leg. The ACME leg (and the step-ca sidecar) was removed on 2026-07-03; hardware trust is MDM SecurityInfo only. The exporter still stages this directory if present on an old disk, but it does **not** need to be migrated — destroy it rather than carry it forward.

EigenCloud gives no shell into `/mnt/disks/userdata`, so the only way to carry this state to another Confidential VM **without re-enrolling the whole fleet** is to ship a coordinator build that can read it and emit it — encrypted to a key the operator holds offline. That is `GET /v1/admin/state-export`.

Everything else the new coordinator needs is already portable: the env/KMS secrets (operator has the `.env`), the `MNEMONIC` (carried byte-identical), and the database (the same AWS RDS, cross-cloud).

Canonical code paths:

- HTTP handler: [`coordinator/api/admin_state_export.go`](../../coordinator/api/admin_state_export.go):56–206
- Archiver (snapshot + zip): [`coordinator/stateexport/archive.go`](../../coordinator/stateexport/archive.go)
- Env gates: [`coordinator/api/admin_state_export.go`](../../coordinator/api/admin_state_export.go):18–29

## Prerequisites

- [ ] A coordinator build that contains the `/v1/admin/state-export` handler.
- [ ] `age` installed on the offline machine (`brew install age` or `apt install age`).
- [ ] `EIGENINFERENCE_ADMIN_KEY` for the source coordinator.
- [ ] Access to the source coordinator's KMS/env to set `EIGENINFERENCE_STATE_EXPORT_ENABLED` and `EIGENINFERENCE_STATE_EXPORT_RECIPIENT`.
- [ ] A target Confidential VM provisioned with the same coordinator image and persistent disk path `/mnt/disks/userdata`.
- [ ] Source and target share the same `MNEMONIC` and database DSN.

## Steps

### 0. Generate the offline recipient keypair (once)

On a trusted, ideally offline machine:

```bash
age-keygen -o dar70-export-identity.txt
# prints: Public key: age1qz...   <-- this is the RECIPIENT
```

Keep `dar70-export-identity.txt` (the private identity) offline. Only the `age1...` **public** recipient goes to the coordinator.

### 1. Enable the endpoint on the source coordinator (human-only)

Set via the source coordinator's KMS/env and redeploy the build that contains the endpoint:

```bash
EIGENINFERENCE_STATE_EXPORT_ENABLED=true
EIGENINFERENCE_STATE_EXPORT_RECIPIENT=age1qz...      # the offline public key
# EIGENINFERENCE_ADMIN_KEY is already set
```

Defaults are fail-closed: with `ENABLED` unset the route returns **404**; with no recipient set and `ALLOW_PLAINTEXT` unset it returns **412** (encrypted-by-default). See [`coordinator/api/admin_state_export.go`](../../coordinator/api/admin_state_export.go):61–99.

### 2. Extract (one authenticated request)

```bash
curl -fSL https://api.darkbloom.dev/v1/admin/state-export \
  -H "Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY" \
  -o darkbloom-state.zip.age
```

The coordinator:

1. Snapshots every `*.db` consistently (hot-copy + validate + retry — MicroMDM keeps the live DB locked).
2. Stages `micromdm/**` (excluding `*.log`, including `.push_imported`) — plus legacy `step-ca/**` if the old disk still has it — into a `0700` temp dir.
3. Zips the staged tree and **age-encrypts the stream to your recipient**.

No plaintext is ever written to the coordinator's disk or logs. The export root defaults to `/mnt/disks/userdata`; it can be overridden with `EIGENINFERENCE_STATE_EXPORT_ROOT` or `USER_PERSISTENT_DATA_PATH`. See [`coordinator/api/admin_state_export.go`](../../coordinator/api/admin_state_export.go):33–38.

### 3. Decrypt + verify (offline)

```bash
age --decrypt -i dar70-export-identity.txt -o darkbloom-state.zip darkbloom-state.zip.age

unzip -l darkbloom-state.zip            # expect micromdm/micromdm.db, micromdm/.push_imported (legacy disks may also contain step-ca/... — not needed, do not migrate it)
unzip -d /tmp/verify darkbloom-state.zip
# Sanity-check the BoltDB opens:
ls -l /tmp/verify/micromdm/             # micromdm.db, push.crt, push.key, .push_imported
```

### 4. Rehydrate on the target Confidential VM — BEFORE first coordinator boot

The container's `start.sh` only generates fresh MicroMDM server keys / imports the push cert when the corresponding files are absent. Land the extracted tree at `/mnt/disks/userdata` **before** the coordinator first runs, so the real state is preserved:

```bash
# Copy the decrypted zip to the CVM, then on the CVM:
sudo mkdir -p /mnt/disks/userdata
sudo unzip -o darkbloom-state.zip -d /mnt/disks/userdata
# Modes are preserved by the zip; confirm secrets stay tight:
sudo chmod 600 /mnt/disks/userdata/micromdm/push.key
```

Inject `MNEMONIC` (byte-identical) and the rest of the secret set into the target KMS/Secret Manager, then start the coordinator. **Do not start the coordinator before the tree is in place** — `start.sh` would generate fresh MicroMDM state and you would have to re-export.

### 5. Disable the endpoint (human-only)

Immediately after a successful extraction:

```bash
EIGENINFERENCE_STATE_EXPORT_ENABLED=false   # or unset, then redeploy → route returns 404 again
```

Then handle the artifacts per policy: the `.zip.age` is only decryptable with the offline identity; destroy the decrypted `.zip` and `/tmp/verify` once rehydration is verified.

## Verification

| Check | Expected outcome |
|---|---|
| `GET /v1/encryption-key` `kid` matches source | Proves `MNEMONIC` continuity. Endpoint: [`coordinator/api/consumer.go`](../../coordinator/api/consumer.go) (encryption-key handler) |
| A known-enrolled Mac pointed at the target completes SecurityInfo and reaches hardware trust | Proves BoltDB + push-cert continuity |
| SCEP re-enroll works against the carried MicroMDM state | Proves SCEP/enrollment continuity |
| APNs attestor logs ENABLED; MDM webhook returns 200 | Proves push cert + webhook secret continuity |

## Rollback

- **Before DNS cutover:** simply do not repoint traffic. The source coordinator remains authoritative.
- **After cutover:** revert DNS to the source coordinator. The source still holds the original `/data` and the same database, so providers reconnect and re-earn hardware trust transparently.
- **If rehydration fails:** stop the target coordinator before `start.sh` generates fresh MicroMDM state, fix the state tree, and retry. If fresh state was already created, delete `/mnt/disks/userdata/micromdm` and re-land the exported tree.

## Security properties

- **Off by default** — the route is 404 unless `STATE_EXPORT_ENABLED=true`.
- **Admin-key only** — constant-time, length-leak-free SHA-256 digest comparison; the Privy-admin path is intentionally **not** accepted. See [`coordinator/api/admin_state_export.go`](../../coordinator/api/admin_state_export.go):72–85.
- **Encrypted by default** — the archive is age-encrypted to an offline recipient; a raw zip requires explicit `STATE_EXPORT_ALLOW_PLAINTEXT=true`.
- **Consistent + fail-loud** — BoltDB is snapshotted with hot-copy + byte-level validation + retry; a torn copy or a degenerate (empty / missing MicroMDM DB) export fails as a clean pre-stream **500**, never a truncated 200. See [`coordinator/stateexport/archive.go`](../../coordinator/stateexport/archive.go):96–225.
- **No plaintext residue** — staged snapshots live in one `0700` temp dir that is always removed; nothing sensitive is logged (only counts, addr, outcome).

> The transit encryption (age, to your offline key) is the real protection for the exported bytes — the archive contains the MicroMDM push key in plaintext (and, on legacy disks, old step-ca keys whose at-rest password was public in the old `start.sh`). Treat the `.zip.age` and the offline identity accordingly.

## Where this sits in the migration

`DAR-69` (build the GCP CVM target) → **`DAR-70` (this — extract + rehydrate)** → `DAR-105` (security review of the exfil path) → `DAR-71` (DNS cutover to the CVM; rollback = revert DNS). The domain stays `api.darkbloom.dev` throughout; the `.dev → .ai` move is a separate, later project.
