# State export

> Last updated: 2026-09-03 · commit `5d400cf75`

How to pull the coordinator's sealed on-disk state — the MicroMDM enrollment
database and everything else on the persistent disk that is not in Postgres —
out of a running Confidential VM through `GET /v1/admin/state-export`, and how
to land it on a replacement VM without re-enrolling the fleet. The endpoint was
built for the EigenCloud → GCP move (DAR-70;
[`../reports/2026-07-17-eigencloud-to-gcp-migration.md`](../reports/2026-07-17-eigencloud-to-gcp-migration.md));
it is the general tool for moving that disk between hosts.

> Production use needs explicit human approval for the specific operation.
> Enabling the route, running the extraction and disabling it again are each
> production changes. Without approval this page is command preparation only.

## What is on the disk

`/mnt/disks/userdata` (symlinked to `/data` by `coordinator/deploy/start.sh`)
holds state that the database does not:

| Path | What it is | Must it move? |
|---|---|---|
| `/data/micromdm/micromdm.db`, `push.crt`, `push.key`, `.push_imported` | The MicroMDM BoltDB — the enrolled-device records the hardware-trust check reads — plus the APNs push certificate and its import sentinel | **Yes.** Without it every provider drops to `self_signed` trust until it re-enrolls. |
| `/data/coordinator/trust-reuse-hard-untrust.v1.jsonl` | The hard-untrust revocation journal (`coordinator/api/trust_reuse_journal.go`) | Yes, or revocations issued on the old host are forgotten. |
| `/data/prompt-contracts/` | Downloaded prompt-contract artifacts (`DefaultArtifactRoot` in `coordinator/promptcontract/artifact_cache.go`) | No — re-provisioned from the CDN; it only makes the archive larger. |
| `/data/step-ca/` | Legacy ACME `device-attest-01` CA keys; the leg was removed on 2026-07-03 | No. Destroy rather than carry forward. |

Everything else a replacement coordinator needs is already portable: the
environment file, the `MNEMONIC` (byte-identical) and the shared database
(`EIGENINFERENCE_DATABASE_URL`).

## How the endpoint works

Code: `coordinator/api/admin_state_export.go` (`handleAdminStateExport`,
`resolveStateExportRoot`), `coordinator/stateexport/archive.go`
(`Archiver.Stage`, `Archiver.Write`), `coordinator/stateexport/snapshot.go`
(`BoltSnapshotter`), `coordinator/stateexport/encrypt.go` (`EncryptWriter`).

1. **Gate.** Unless `EIGENINFERENCE_STATE_EXPORT_ENABLED=true` the route
   answers 404, indistinguishable from an unregistered path.
2. **Auth.** Admin key only: SHA-256 digests of the bearer token and the key
   are compared in constant time, so neither the key nor its length leaks.
   Privy admins are deliberately refused (403) — this endpoint exfiltrates key
   material.
3. **Output protection.** `EIGENINFERENCE_STATE_EXPORT_RECIPIENT` must hold an
   `age1…` public recipient; without it the route answers 412 unless
   `EIGENINFERENCE_STATE_EXPORT_ALLOW_PLAINTEXT=true`. A malformed recipient is a
   clean 500 before any byte is written.
4. **Stage.** The root (`EIGENINFERENCE_STATE_EXPORT_ROOT`, else
   `USER_PERSISTENT_DATA_PATH`, else `/mnt/disks/userdata`) is resolved through
   symlinks and walked. Every `*.db` is hot-copied, validated as BoltDB and
   retried into a fresh `0700` staging directory; symlinks and `*.log` files
   are skipped. The stage fails — as a pre-stream 500 — when the walk would
   capture zero files, or when a `micromdm/` directory exists but no BoltDB
   inside it was snapshotted. A `step-ca/db` Badger directory is copied
   file-by-file with a warning.
5. **Write.** The whole tree under the root is zipped with relative paths and
   modes preserved, `*.db` entries replaced by their validated snapshots, and
   the stream is age-encrypted to the recipient. The response is
   `attachment; filename="darkbloom-state-<epoch>.zip.age"` (or `.zip` when
   plaintext was allowed). The staging directory is removed afterwards.

Logs carry counts, the remote address and the outcome only.

## Prerequisites

- [ ] `age` on an offline machine (`brew install age` or `apt install age`).
- [ ] `EIGENINFERENCE_ADMIN_KEY` of the source coordinator.
- [ ] Write access to the source coordinator's environment file (see
      [`coordinator-deploy.md#environment-file`](coordinator-deploy.md#environment-file))
      to set the three `EIGENINFERENCE_STATE_EXPORT_*` variables.
- [ ] A target Confidential VM with the same image and a persistent disk at
      `/mnt/disks/userdata` that the coordinator has **not yet booted against**.
- [ ] Source and target share `MNEMONIC` and the database DSN.

## Steps

### 0. Generate the offline recipient (once)

```bash
age-keygen -o state-export-identity.txt
# prints: Public key: age1...   <-- the RECIPIENT
```

Only the `age1…` public half goes to the coordinator; the identity file stays
offline.

### 1. Enable the route on the source coordinator (approval required)

Add to the environment file and restart the container:

```bash
EIGENINFERENCE_STATE_EXPORT_ENABLED=true
EIGENINFERENCE_STATE_EXPORT_RECIPIENT=age1...
```

The route is read live from the process environment, so a restart is what
applies it. Defaults are fail-closed: 404 with `ENABLED` unset, 412 with no
recipient and plaintext not allowed.

### 2. Extract

```bash
curl -fSL https://api.darkbloom.dev/v1/admin/state-export \
  -H "Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY" \
  -o darkbloom-state.zip.age
```

If MicroMDM is being written to (enrollments in flight) quiesce it first; the
BoltDB snapshot is consistent on its own, but a `step-ca/db` directory is not.

### 3. Decrypt and verify (offline)

```bash
age --decrypt -i state-export-identity.txt -o darkbloom-state.zip darkbloom-state.zip.age
unzip -l darkbloom-state.zip
# expect micromdm/micromdm.db, micromdm/push.crt, micromdm/push.key, micromdm/.push_imported,
# coordinator/trust-reuse-hard-untrust.v1.jsonl; possibly prompt-contracts/** and legacy step-ca/**
unzip -d /tmp/verify darkbloom-state.zip
ls -l /tmp/verify/micromdm/
```

### 4. Land the tree on the target before its first coordinator boot

`coordinator/deploy/start.sh` imports the push certificate only when
`/data/micromdm/push.crt` is absent, and MicroMDM generates fresh server keys
when its directory is empty. Put the exported tree in place first:

```bash
sudo mkdir -p /mnt/disks/userdata
sudo unzip -o darkbloom-state.zip -d /mnt/disks/userdata
sudo rm -rf /mnt/disks/userdata/step-ca /mnt/disks/userdata/prompt-contracts   # not needed
sudo chmod 600 /mnt/disks/userdata/micromdm/push.key
```

Then inject `MNEMONIC` and the rest of the secret set and start the
coordinator. Starting it first would create fresh MicroMDM state and force a
re-export.

### 5. Disable the route (approval required)

Remove or set `EIGENINFERENCE_STATE_EXPORT_ENABLED=false` and restart; the
route returns 404 again. Destroy the decrypted `.zip` and `/tmp/verify` once
rehydration is verified; the `.zip.age` is only readable with the offline
identity.

## Verification

| Check | Proves |
|---|---|
| `GET /v1/encryption-key` returns the same `kid` on source and target | `MNEMONIC` continuity |
| A known-enrolled Mac pointed at the target completes SecurityInfo and reaches `hardware` trust | BoltDB and push-certificate continuity |
| SCEP re-enrollment succeeds against the carried MicroMDM state | Enrollment continuity |
| Startup logs show the APNs attestor enabled and `POST /v1/mdm/webhook` returns 200 | Push certificate and webhook secret continuity |
| A provider hard-untrusted on the source stays untrusted on the target | Revocation journal continuity |

## Rollback

- **Before DNS cutover:** do nothing; the source remains authoritative.
- **After cutover:** revert DNS. The source still holds its disk and shares
  the database, so providers reconnect and re-earn trust transparently.
- **Rehydration failed:** stop the target before `start.sh` creates fresh
  MicroMDM state, fix the tree, retry. If fresh state already exists, delete
  `/mnt/disks/userdata/micromdm` and re-land the export.

## Security properties

- **Off by default** and **admin key only**; the Privy-admin path is refused.
- **Encrypted by default** to an offline recipient; plaintext needs an
  explicit opt-in.
- **Consistent or nothing.** A torn BoltDB copy, an empty walk or a missing
  MicroMDM database fails as a pre-stream 500, never a truncated 200.
- **No plaintext residue** on the coordinator: one `0700` staging directory,
  always removed; no file contents in logs.
- The archive itself contains the MicroMDM push key in the clear (and old
  step-ca keys on a legacy disk). The age layer is the real protection for the
  bytes in transit and at rest; treat the identity file accordingly.

## Related

- [`../reference/configuration.md`](../reference/configuration.md) — the `EIGENINFERENCE_STATE_EXPORT_*` and `USER_PERSISTENT_DATA_PATH` rows
- [`coordinator-deploy.md`](coordinator-deploy.md) — the persistent-disk bind mount and the environment file
- [`../architecture/storage.md`](../architecture/storage.md) — what lives in Postgres versus on the disk
- [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md) — why the MicroMDM database is the state that matters
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — the admin route inventory
