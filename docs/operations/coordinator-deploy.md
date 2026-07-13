# Coordinator and provider deployment

This runbook covers the dual Go/Rust coordinator image and the provider bundle.
Production deployment is human-only. Agents and CI may build and validate the
production image, but must never execute the production deploy.

## Prerequisites

- Run `make coordinator`, `make coordinator-rs`, and
  `deploy/gcp/tests/run.sh`.
- Confirm the candidate image was built from the intended commit.
- Confirm VM metadata contains an immutable `DINF_GO_FALLBACK_IMAGE` before a
  Rust cutover.
- Confirm `/mnt/disks/userdata` is mounted on the VM.
- Read the ownership rollout in
  [coordinator-ownership-rollout.md](coordinator-ownership-rollout.md).
- For any Rust pilot, canary, handoff, bake, or retirement action, verify the
  current signed authorization from
  [coordinator-cutover.md](coordinator-cutover.md). The authorization is
  preflight evidence only and does not replace this runbook's typed human
  production confirmations.

## Topology

| Item | Dev | Prod |
|---|---|---|
| Project | `sepolia-ai` | `darkbloom-mainnet` |
| VM | `d-inference-dev`, `us-central1-a` | `darkbloom-coordinator`, `us-east4-a` |
| Deploy entry point | [`deploy/gcp/deploy-dev.sh`](../../deploy/gcp/deploy-dev.sh), called by Cloud Build | [`deploy/gcp/deploy-prod.sh`](../../deploy/gcp/deploy-prod.sh), interactive human only |
| Image | One image containing Go, Rust, and the Go migrator | Same |
| Serving owner | One host-network `d-inference-coordinator` container supervised by systemd | Same |
| Database owner | One process holding the shared Go/Rust PostgreSQL advisory lock | Same |
| Persistent state | Host `/mnt/disks/userdata` bind-mounted at the same path | Same |
| Secrets | Secret Manager → root-only `/etc/d-inference/env` plus read-only mounted secret files | Same |
| TLS | Host Caddy → `127.0.0.1:8080` | Same |
| Recovery | Offline, mutually exclusive systemd unit | Same |

The image contract lives in
[`coordinator/Dockerfile`](../../coordinator/Dockerfile). It ships:

- `/usr/local/bin/coordinator-go`
- `/usr/local/bin/coordinator-rs`
- `/usr/local/bin/coordinator-migrate`
- `/usr/local/bin/coordinator` as a compatibility symlink to Go

[`coordinator/deploy/start.sh`](../../coordinator/deploy/start.sh) accepts only
`EIGENINFERENCE_COORDINATOR_BINARY=go|rust`; unset defaults to Go. It uses an
exact shell `case`, never `eval`.

## Serial handoff invariant

The canonical transaction is implemented in
[`deploy/gcp/remote-deploy.sh`](../../deploy/gcp/remote-deploy.sh):

1. Pull the candidate and resolve its immutable registry digest.
2. Before any database migration, run the image smoke check and validate its
   layout, selected binary/version, required secrets, offline configuration,
   persistent mount, decrypted MDM/profile identities, certificate
   validity/usage, and—when an installed MDM hash/version will rotate—the
   authenticated local MicroMDM API.
3. Run the image's external Go migrator while the old owner is serving.
4. Call `POST /v1/admin/drain` with `{"mode":"handoff"}`. The irreversible
   handoff fence rejects new inference and mutations, closes Go provider
   sessions, and cancels tracked mutating loops while admitted completion and
   settlement work drains.
5. Poll `GET /v1/admin/quiescence` until request, writer, settlement, durable
   recovery, external-operation, outbox, telemetry, provider, and background
   counters are safe. A timeout aborts with the old process still fenced; a
   handoff can never be undone.
6. Stop the old systemd service, release PostgreSQL ownership, and rename the
   stopped container for incident inspection. A one-time legacy `--rm`
   container is first snapshotted into a stopped, non-serving clone.
7. With no owner running, execute the candidate invariant gate. Go candidates
   call `coordinator-go rollback-check`; Rust candidates call
   `coordinator-rs invariant-scan`.
8. Start exactly one host-network candidate.
9. Poll `/readyz`, `/health`, `/v1/providers/attestation`, and
   `/v1/admin/routes`; validate the expected build commit, provider/trust
   recovery, container count, state mount, and committed MDM rotation marker.
10. Only after success, commit the image digest, binary selector, pinned Go
    fallback, and startup files to VM metadata.

Migration and candidate failure paths never commit candidate boot metadata.
There is no blue/green overlap: the old owner stops before a candidate,
invariant command, or fallback can acquire ownership or bind port 8080.
`/run/d-inference/deploy-result.env` is also a transaction fence: a second
deploy is refused while a validated candidate is awaiting metadata commit or
explicit rollback. Do not delete that file to bypass an interrupted handoff;
complete the pinned-Go rollback procedure first.

## Dev deployment

Cloud Build uses
[`deploy/gcp/cloudbuild.yaml`](../../deploy/gcp/cloudbuild.yaml). Its default
selector is Go until cutover:

```bash
gcloud builds submit \
  --project=sepolia-ai \
  --config=deploy/gcp/cloudbuild.yaml
```

To exercise Rust after all cutover gates pass:

```bash
gcloud builds submit \
  --project=sepolia-ai \
  --config=deploy/gcp/cloudbuild.yaml \
  --substitutions=_COORDINATOR_BINARY=rust
```

`_ADOPT_LEGACY=true` is allowed only for the one-time, fingerprint-validated
legacy schema adoption. Routine deploys keep it `false`.

Cloud Build pushes the immutable SHA tag before deployment. The mutable
`latest` tag advances only after deployment succeeds.

## Production deployment

CI has no production deploy step. The production script refuses CI/agent
environments and non-interactive input. A human operator must read this
runbook, set the explicit acknowledgement, and answer four typed confirmations:

```bash
export DINF_HUMAN_PROD_DEPLOY=I_AM_A_HUMAN
deploy/gcp/deploy-prod.sh \
  <go-image@sha256:digest> go <full-40-char-commit> \
  <go-image@sha256:digest> -
```

Rust additionally requires a self-contained, signed `full-cutover`
authorization. Before any remote migration or drain, the script verifies it
against the fixed operator-host gate and approver public keys and checks the
current policy hash/version, human approval, complete predecessor chain,
environment, age, commit, and distinct immutable candidate/fallback images:

```bash
deploy/gcp/deploy-prod.sh \
  <rust-image@sha256:digest> rust <full-40-char-commit> \
  <go-image@sha256:digest> <full-cutover.authorization.json>
```

The script prints the account, project, zone, VM, image, selector, commit, and
transaction before changing anything. It asks for a second `COMMIT-METADATA`
confirmation after the live candidate passes.

Do not invoke this script from an agent, automation, cron, or Cloud Build.

## Verification

The deploy transaction performs these checks automatically. Operators can
repeat them without exposing secrets:

```bash
curl -fsS https://api.darkbloom.dev/health | jq .
curl -fsS https://api.darkbloom.dev/readyz | jq .
curl -fsS https://api.darkbloom.dev/v1/providers/attestation |
  jq '{providers: (.providers | length), hardware: ([.providers[] | select(.trust_level=="hardware")] | length)}'
sudo docker inspect d-inference-coordinator \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{println}}{{end}}'
sudo docker ps --filter label=com.darkbloom.role=serving
```

Expected:

- `/readyz` is `200` with `ready:true`.
- `/health.build_commit` matches the candidate.
- Exactly one serving container is running.
- `/mnt/disks/userdata` is mounted read-write at the same container path.
- Hardware-trusted providers reconnect after a fleet existed before the swap.

## Automatic rollback

On candidate invariant, startup, health, trust, route, container, or mount
failure, the remote deploy:

1. Handoff-drains the failed candidate and requires detailed quiescence,
   including webhooks and other external operations.
2. Stops and preserves the failed candidate only after quiescence.
3. Restores the immutable previous-known-good env and file-secret snapshot.
4. Starts the metadata-pinned Go image as a one-shot
   `coordinator-go rollback-check`.
5. That command acquires exclusive ownership and calls
   `store.PostgresStore.CheckRollbackSafe` in
   [`coordinator/store/postgres_rollback.go`](../../coordinator/store/postgres_rollback.go).
6. Only a successful check permits the pinned Go serving container to start.

If handoff or quiescence fails, the script does not stop the candidate or start
a fallback. It disables automatic service restart, pauses the candidate as the
sole fenced container, writes `/run/d-inference/automatic-rollback-refused`,
and requires manual recovery. Pausing prevents new local or external mutation
without pretending in-flight external outcomes are known. An unsafe rollback
check also returns a distinct failure. Never bypass either fence by starting an
older Go image manually; unresolved durable or external work may be financially
ambiguous.

If the metadata API reports failure after a candidate passed, the result is
treated as an unknown write outcome. The script first validates and starts the
pinned Go fallback, then explicitly commits that verified Go digest and
selector so live state and reboot state cannot diverge.

The stopped pre-swap and failed containers remain on the VM under timestamped
names. They do not own the host port or database lock.

## Offline recovery worker

[`d-inference-recovery.service`](../../deploy/gcp/systemd/d-inference-recovery.service)
runs `coordinator-rs recovery` from the same metadata-pinned image. The Rust
recovery command acquires the same primary ownership lock as serving, so this
unit is deliberately an offline maintenance mode, not a sidecar.

```bash
# First drain and stop serving, then verify no serving container remains.
sudo touch /etc/d-inference/enable-offline-recovery
sudo systemctl start d-inference-recovery.service

# After recovery:
sudo systemctl stop d-inference-recovery.service
sudo rm /etc/d-inference/enable-offline-recovery
sudo systemctl start d-inference-coordinator.service
```

The systemd units deliberately do not use `Conflicts=` because starting one
unit must never silently stop the other. Both launchers hold the same host
`flock` for their full container lifetime and independently refuse overlap.
The recovery process then acquires the same PostgreSQL ownership lock itself.
Both launchers require the metadata image to be an immutable `sha256` digest.

## Secrets and configuration

[`refresh-env.sh`](../../deploy/gcp/refresh-env.sh) fetches secrets from the
explicit immutable `DINF_GCP_PROJECT` metadata project, rejects missing critical or multiline
values, writes a mode-`0600` temporary file, and atomically replaces
`/etc/d-inference/env`. Multiline material such as the Privy verification key
is stored under mode-`0600` `/etc/d-inference/secrets` and mounted read-only at
`/run/d-inference-secrets`. It never prints values. The selector and image are
not stored in the env file; they remain independently validated VM metadata.
Before replacement, the serving env and secret directory are copied to an
immutable timestamped `/etc/d-inference/previous-known-good/` snapshot. The
deploy transaction records only its root-owned pointer. Any automatic Go
fallback restores that exact snapshot before `rollback-check` or serving
startup and rebuilds its admin-auth config from the restored key.

MicroMDM push-certificate rotation compares both the Secret Manager version and
the decoded PKCS#12 SHA-256. Before migration, image preflight decrypts both the
required MDM and configured profile-signing bundles with their configured
passwords; requires exactly one matching leaf/private-key identity; and checks
certificate validity, non-CA/digital-signature usage, plus MDM client-auth or
profile code-signing extended usage. If MDM hash/version changed, it also makes
an authenticated request to the currently serving local MicroMDM API.

A changed MDM identity is uploaded with bounded retries and only then atomically
replaces `push.crt`, `push.key`, and the hash/version marker. Decode or upload
failure leaves the prior working files and marker unchanged, so it retries on
the next start. With a valid previously uploaded identity, startup records a
rotation-failure metric marker but keeps MicroMDM and the coordinator reachable
for candidate verification and handoff. Candidate verification still fails
until the requested marker/hash commits, causing the normal quiesced Go
fallback. A first install without a valid committed identity fails closed.

[`configure-caddy.sh`](../../deploy/gcp/configure-caddy.sh) validates and
atomically reloads the host proxy on every deploy and boot. It overwrites
forwarded identity headers from the transport-derived client address and
removes untrusted alternate client-IP headers before proxying to localhost.

The checked-in non-secret matrix is:

- [`deploy/environments/dev.env`](../../deploy/environments/dev.env)
- [`deploy/environments/prod.env`](../../deploy/environments/prod.env)

Both environments enable ownership and contain configuration for both
binaries, while metadata keeps the selected serving binary on Go until
cutover.

## Provider bundle release

Provider bundles remain independent of coordinator deployment.
`.github/workflows/release-swift.yml` builds, signs, notarizes, hashes after
signing, uploads to the environment-specific R2 bucket, and registers the
release through `POST /v1/releases`.

Never create a provider release unless explicitly requested. Dev tags use
`vX.Y.Z-dev.N`; production tags use `vX.Y.Z`.
