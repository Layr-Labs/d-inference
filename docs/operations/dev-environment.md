# Dev environment

> Last updated: 2026-10-06

Runbook for the Darkbloom dev coordinator in the GCP project `darkbloom-dev`.
Dev uses the production env contract, the production build file and the
production swap steps of [coordinator-deploy.md](coordinator-deploy.md).
Scripts do the steps that a human does in production. Nothing here touches
production (`darkbloom-mainnet`).

## When to use

- The first host setup and the first deploy of the dev coordinator (Linear
  DBLM-559).
- A manual deploy or rollback of the dev coordinator.
- The automatic deploys from `master` (`deploy-dev.yml`), and their pause.
- A change of a dev secret or a dev setting.
- A dev provider release, a dev Mac, or synthetic data in the dev database.

## Prerequisites

- The infrastructure exists. The Terraform in
  [Layr-Labs/darkbloom-devnet-infra](https://github.com/Layr-Labs/darkbloom-devnet-infra)
  makes the VM, the disks, the IP address, the firewall rules, Cloud SQL, the
  Secret Manager containers, Artifact Registry, the trigger `dev-build` and the
  deploy identity. Do not make dev resources by hand. Do not use a bootstrap
  script.
- `gcloud` logged in as a person with IAP tunnel access, OS Login admin and
  `iam.serviceAccounts.actAs` on `d-inference-dev@darkbloom-dev.iam.gserviceaccount.com`.
  A project owner has all three.
- `git`, `dig`, `jq` and `gh` on your machine (`mise install`). `gh` must be
  able to read the repository variable `DEV_DEPLOY_PAUSED`.
- The secret values and DNS records of DBLM-558 (section "Secrets" below).
- A clean, detached checkout of `origin/master`. Every script reads its files
  from that checkout:

  ```bash
  git -C <d-inference clone> fetch origin
  git -C <d-inference clone> worktree add --detach <path>/dev-deploy origin/master
  cd <path>/dev-deploy && test -z "$(git status --porcelain)" && echo clean
  ```

### What dev looks like

| Item | Dev | Production |
|---|---|---|
| VM | `d-inference-dev`, zone `us-east4-a`, `c3d-highcpu-4`, AMD SEV, Shielded VM, IAP SSH only | `darkbloom-coordinator`, `c3d-highcpu-30` |
| Host names | API `api.dev.darkbloom.dev`; console `console.dev.darkbloom.dev` (pending confirmation). Change them in one place: `DOMAIN` and `EIGENINFERENCE_CONSOLE_URL` in [`deploy/gcp/dev/env-overrides`](../../deploy/gcp/dev/env-overrides). The other URLs, the Caddy site and the script defaults come from these two keys | `api.darkbloom.dev` |
| Ingress | Host Caddy, certificate from ACME (HTTP-01). `/scep` and `/mdm/*` go to MicroMDM on `127.0.0.1:9002`, all other paths to `127.0.0.1:8080` | Host Caddy, static certificate |
| Image | `us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator:<SHORT_SHA>`, built by the trigger `dev-build` with [`deploy/gcp/cloudbuild-prod.yaml`](../../deploy/gcp/cloudbuild-prod.yaml). Only `_IMAGE` is different | the same file, trigger `prod-build` |
| `/health` | `version` = `LatestProviderVersion`, `build_commit` = the full commit | the same |
| Container | `coordinator`, the production flags (`--stop-timeout 75`, `EIGENINFERENCE_DRAIN_GRACE=45s`) | the same |
| Env file | `/etc/d-inference/env`, root `0600`, boot disk. Seeded once by [`deploy/gcp/dev/seed-env.sh`](../../deploy/gcp/dev/seed-env.sh), then kept by the production refresh | Written by hand, kept by the production refresh |
| Boot refresh | [`deploy/gcp/prod/darkbloom-env-refresh.service`](../../deploy/gcp/prod/darkbloom-env-refresh.service) | the same |
| Database | Cloud SQL `d-inference-dev-db` (PostgreSQL 17, private IP only, `sslmode=require`) | Cloud SQL, private IP |
| Data disk | `/mnt/disks/userdata` (MicroMDM BoltDB, prompt artifacts) | the same |
| Swap | [`deploy/gcp/dev/swap.sh`](../../deploy/gcp/dev/swap.sh), started by [`deploy/gcp/dev/deploy.sh`](../../deploy/gcp/dev/deploy.sh) | a human |
| Approval | A reviewed merge to `master`. The repository variable `DEV_DEPLOY_PAUSED` stops deploys | a human, the deploy record |
| Rollback target | `/var/lib/darkbloom-deploy/last-good-image`, written by the last verified swap | `APPROVED_PREVIOUS_IMAGE` in the deploy record |
| Console UI | Vercel project `darkbloom-console-dev` | Vercel production project |
| Release bucket | Cloudflare R2 `d-inf-app-dev`; its public URL is secret `eigeninference-r2-cdn-url` | R2 `d-inf-app` |
| Model files | The production model CDN, read only (`MODEL_REGISTRY_CDN_BASE_URL` is not set) | the same |

### Dev settings

The overlay [`deploy/gcp/dev/env-overrides`](../../deploy/gcp/dev/env-overrides)
holds values only. A value `secret-manager:<name>` comes from Secret Manager.
A literal can use `${KEY}` for an earlier literal key of the overlay. The seed
takes the first value it finds: the overlay, then the `EIGENINFERENCE_*` lines
of [`deploy/environments/prod.env`](../../deploy/environments/prod.env). The
production refresh then adds the release defaults. The overlay is different
from production at these keys:

| Key | Dev value | Reason |
|---|---|---|
| `EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT` | `development` | The default is `production`, which requires the App Attest cutover settings ([deployment setting](../reference/configuration.md#deployment-environment)) |
| `EIGENINFERENCE_MIN_TRUST` | `self_signed` | Dev has no Apple credentials yet (DBLM-564) |
| `EIGENINFERENCE_CACHE_ROUTING_MODE` | `off` | `on` needs `EIGENINFERENCE_CACHE_MASTER_KEY` and an operator allowlist |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED` | `false` | `true` needs the Global Payouts account and webhook secret; the refresh check then fails |
| `EIGENINFERENCE_WARM_POOL_MIN_WARM` | `Qwen3.5-9B=1` | The production value names models that dev does not have |
| `APNS_KEY_ID`, `APNS_AUTH_KEY_P8_B64`, `APNS_ENFORCE_AFTER` | placeholders | The keys are required. The placeholder `.p8` does not parse, so APNs attestation is off. Expect the log line `failed to construct APNs attestor — attestation disabled` |
| `APNS_MODE`, `APNS_TOPIC`, `EIGENINFERENCE_PORT`, the five `EIGENINFERENCE_SERVICE_*` keys | code defaults | Required keys that `prod.env` does not record |
| `EIGENINFERENCE_TRUST_GEO_HEADERS` | `0` | Required key. Code default: off (`coordinator/api/geo/resolver.go`) |
| `EIGENINFERENCE_STATE_EXPORT_ENABLED` | `false` | Required key. Code default: off (`coordinator/api/operations/state_export.go`) |
| `EIGENINFERENCE_DRAIN_GRACE` | `45s` | The production shutdown policy of [coordinator-deploy.md](coordinator-deploy.md#4-swap) |

Dev does not set `EIGENINFERENCE_IPAPI_KEY`: its secret is not one that the VM
account can read. Geo lookups use the free tier.

### Secrets

The overlay names 22 Secret Manager containers. The VM account
`d-inference-dev@` can read exactly these 22 (`coordinator_secret_ids` in
darkbloom-devnet-infra `terraform/secrets/locals.tf`). To use another secret,
change that list and the overlay in the same change. Add a value:

```bash
echo -n '<value>' | gcloud secrets versions add <secret-name> --data-file=- --project=darkbloom-dev
```

Rules for values:

- Never copy a production value into dev.
- Each value is one line. Store a PEM key with `\n` escapes.
- `eigeninference-database-url`:
  `postgres://coordinator:<password>@<private ip>:5432/eigeninference?sslmode=require`.
- `eigeninference-release-key` equals the GitHub secret `DEV_RELEASE_KEY`.
  `eigeninference-r2-cdn-url` equals `DEV_R2_PUBLIC_URL`
  ([provider-release.md](provider-release.md)).
- `eigeninference-mdm-push-p12-b64`: a throwaway self-signed RSA PKCS#12
  (password `eigeninference`, base64url) until DBLM-564.

### Deploy pause

`deploy.sh` reads the repository variable `DEV_DEPLOY_PAUSED` before it
changes anything. It uses the environment variable `DEV_DEPLOY_PAUSED` when it
is set (a workflow passes `vars.DEV_DEPLOY_PAUSED`), else
`gh variable get DEV_DEPLOY_PAUSED -R Layr-Labs/d-inference`. It continues only
when the value is `false`. The value `true`, an empty value or a failed read
stops it with exit code 3, and nothing changes. A rollback obeys the same rule.

A human can pass `--override-pause "<reason>"`. The script then prints a
`REPORT pause override by <account> (<user>@<host>): <reason>` line and
continues. An automatic workflow must pass the variable and must not use the
override. `--dry-run` reports the pause state and does not stop.

Pause and resume (a repository admin):

```bash
gh variable set DEV_DEPLOY_PAUSED -R Layr-Labs/d-inference --body true
gh variable set DEV_DEPLOY_PAUSED -R Layr-Labs/d-inference --body false
```

## Steps

### 1. Run the preflight

```bash
deploy/gcp/dev/preflight.sh
```

It checks, in order: the `gcloud` login and the project; the VM is `RUNNING`;
IAP SSH; DNS of `DOMAIN` points at the VM external IP; each secret of the
overlay has an enabled version (names only); Cloud SQL is `RUNNABLE` with a
private IP; a SUCCESS `dev-build` build and an image exist for the `master`
head; and, on the VM, Cloud SQL accepts connections, `host-setup.sh --check`
and `seed-env.sh --check`. Each line is `PASS`, `FAIL` with the fix, or `WARN`
(optional secret). It changes nothing. On the VM it copies `deploy/` to a
temporary directory and removes it.

Before the first host setup, the `host-setup --check` and `seed-env --check`
lines fail. Fix every other `FAIL` line first.

### 2. Set up the host (once)

```bash
SSH=(gcloud compute ssh d-inference-dev --zone=us-east4-a --project=darkbloom-dev --tunnel-through-iap --ssh-key-expire-after=1h)
git archive --format=tar.gz HEAD deploy | "${SSH[@]}" --command='rm -rf ~/setup && mkdir ~/setup && tar -xz -C ~/setup'
"${SSH[@]}" --command='sudo ~/setup/deploy/gcp/host-setup.sh --apply'
```

[`deploy/gcp/host-setup.sh`](../../deploy/gcp/host-setup.sh) installs Docker,
Caddy, `google-cloud-cli`, `jq` and `postgresql-client`; sets the Docker
credentials for `us-east4-docker.pkg.dev`; formats the data disk once and
mounts it at `/mnt/disks/userdata`; installs the production refresh script,
manifests and boot unit as in step 3 of the production runbook; writes the
Caddyfile for `DOMAIN`. It writes no env value and starts no container.
Without `--apply` it only checks. It refuses to run outside `darkbloom-dev`.
Do not run `--apply` during a swap: a Caddy restart reconnects every provider.

### 3. Seed the env file (once)

```bash
"${SSH[@]}" --command='sudo ~/setup/deploy/gcp/dev/seed-env.sh --seed'
"${SSH[@]}" --command='sudo ~/setup/deploy/gcp/host-setup.sh --apply'
```

The seed reads the secrets with the VM account, runs the production
`refresh-env.sh --check` on a temporary file in `/etc/d-inference`, then moves
it into place and runs `--apply`. Expect `OK wrote /etc/d-inference/env`. If a
required value is missing, the seed lists the key names and writes nothing.
Add the values and run it again. The second `host-setup.sh --apply` installs
the Datadog Agent when `DD_API_KEY` has a value.

Run the preflight again. Every line must be `PASS` or `WARN`.

### 4. First deploy

The pause is on until the first deploys pass. Use the override for this step:

```bash
deploy/gcp/dev/deploy.sh --dry-run
deploy/gcp/dev/deploy.sh --override-pause "first deploy DBLM-559"
```

[`deploy/gcp/dev/deploy.sh`](../../deploy/gcp/dev/deploy.sh) checks the pause,
then does step 1 of the production runbook: the checkout is `origin/master`,
`dev-build` builds `deploy/gcp/cloudbuild-prod.yaml`, a SUCCESS build of the
commit exists (it waits up to 20 minutes), and it reads the image digest. Then
it ships `deploy/gcp/prod`, `deploy/gcp/dev` and `prod.env` of the commit to
`/usr/local/lib/darkbloom-deploy/<commit>` and runs `swap.sh` under
`systemd-run`. [`deploy/gcp/dev/swap.sh`](../../deploy/gcp/dev/swap.sh) does
steps 2 to 4, Verification and Rollback: the database lock checks, `docker
pull` by digest, the label checks, `coordinator --migrate-only`, the refresh,
the rollback state, the rename to `coordinator_fallback_<ts>`, `docker stop -t
75`, `docker run`, and the `/health` and `/readyz` checks. A failed hard check
rolls back by itself. The output has `REPORT` lines, one `OK` or `FAIL` line,
and `deployed=true` or `deployed=false`.

`--dry-run` does the read-only part of step 1 and prints what it would ship and
run. `MIGRATE_ONLY=0` skips `--migrate-only`. `SSH_KEY_FILE` selects the SSH
key.

Expected last line from the VM: `OK <commit> drain_s=0 start_to_ready_s=<n>`.
The first deploy has no fallback and no rollback target.

### 5. Second deploy

Run `deploy/gcp/dev/deploy.sh --override-pause "second deploy DBLM-559"`. It
proves the drain, the fallback container and `last-good-image`. Expect
`OK <commit> drain_s=<n> ...` and a stopped `coordinator_fallback_<ts>`.

### 6. Rollback test and reboot test

```bash
deploy/gcp/dev/deploy.sh rollback --override-pause "rollback test DBLM-559"
"${SSH[@]}" --command='sudo reboot' || true
sleep 90
curl -fsS "https://$(awk -F= '$1 == "DOMAIN" { print $2 }' deploy/gcp/dev/env-overrides)/health" | jq -r .build_commit
```

Expect `OK rolled back to sha256:...`, then the same commit after the reboot.
Then set `DEV_DEPLOY_PAUSED` to `false` when automatic deploys may start.

### 7. Automatic deploys

[`.github/workflows/deploy-dev.yml`](../../.github/workflows/deploy-dev.yml)
runs `deploy.sh` from GitHub Actions. It gets a Google token for
`d-inference-dev-deploy@darkbloom-dev.iam.gserviceaccount.com` through the WIF
provider `github-d-inference`. The provider accepts only this file, on
`master`, for the events `push` and `workflow_dispatch`. Do not rename the
file. Do not add a job environment or a pull request trigger.

Triggers:

- A `push` to `master` that changes `coordinator/**`, `deploy/gcp/**`,
  `deploy/environments/prod.env`, `go.mod`, `go.sum`, `.dockerignore` or
  `deploy-dev.yml`. The job starts only when `DEV_DEPLOY_PAUSED` is `false`.
  Otherwise GitHub shows the run as skipped.
- `workflow_dispatch` with the inputs `mode` (`deploy` or `rollback`) and
  `migrate_only` (default `true`).

The deploy step passes `DEV_DEPLOY_PAUSED: ${{ vars.DEV_DEPLOY_PAUSED }}` to
`deploy.sh`, so the pause rule of "Deploy pause" applies to each run, a
dispatch included. A dispatch while the pause is on fails with exit code 3,
and nothing changes. The workflow never uses `--override-pause`.
`scripts/test-dev-deploy.py` fails if that changes.

What one run does:

1. `deploy.sh` waits for the SUCCESS `dev-build` of the commit (up to 20
   minutes), does step 1 and runs `swap.sh` over IAP SSH with a key for this
   run. A commit that is no longer the `master` head stops with
   `deployed=false`; the newer run deploys.
2. Hard gate: the public `/health` reports `status` `ok`, `draining` `false`,
   `version` = `LatestProviderVersion` and the 40-character commit (for a
   rollback, a 40-character commit).
3. Notify only: providers attach again within 120 s, and
   `scripts/smoke-dev.sh`. The workflow has no secrets, so the authenticated
   chat test does not run.
4. When a push changes the `var LatestProviderVersion` line, the job starts
   `release-swift.yml` with `environment=dev` on `master`. It does not wait
   for that run.
5. It removes the SSH key from the OS Login profile and writes the job
   summary: the time from merge to healthy, the `dev-build` times, the swap
   result line and the `REPORT` lines.

Manual runs (always `--ref master`; WIF refuses other branches):

```bash
gh workflow run deploy-dev.yml -R Layr-Labs/d-inference --ref master                      # deploy the master head
gh workflow run deploy-dev.yml -R Layr-Labs/d-inference --ref master -f migrate_only=false
gh workflow run deploy-dev.yml -R Layr-Labs/d-inference --ref master -f mode=rollback      # last verified swap
```

After a pause, set `DEV_DEPLOY_PAUSED` to `false`, then dispatch a deploy:
pushes during the pause did not deploy. The setup runbook (runbook 09) is in
[darkbloom-devnet-infra](https://github.com/Layr-Labs/darkbloom-devnet-infra).

### 8. Change a setting or a secret

- The host file is authoritative, as in production. A change to the overlay or
  a new secret version needs `seed-env.sh --reseed` on the host, then a deploy.
  The reseed builds and checks a new file first. If that fails, the live file
  does not change. If it passes, the old file stays as
  `env.pre-reseed.<UTC>`.
- Or edit `/etc/d-inference/env` by hand, as in production, then deploy.
- `seed-env.sh --check` (and each swap) reports `DRIFT` for overlay keys whose
  live value is different. It prints names, not values.
- Variables are read once at process start. A new value needs a deploy.

### 9. Console UI on Vercel

1. Project `darkbloom-console-dev`, root directory `console-ui/`.
2. Env: `NEXT_PUBLIC_COORDINATOR_URL` = `https://` + `DOMAIN` of the overlay.
3. Add the console host name of the overlay as a domain, then set the CNAME
   that Vercel shows.

The repository-root `vercel.json` and `console-ui/vercel.json` both exclude
exactly `release/0.9.0-validation` from Git deployments. Other branches keep
the default behavior of Vercel.

### 10. Dev provider release

```bash
gh workflow run release-swift.yml --ref <branch> -f environment=dev   # optional -f version_override=X.Y.Z
```

The workflow builds, signs, notarizes, uploads to R2 `d-inf-app-dev` and
registers the release with the dev coordinator with the `DEV_*` secrets. Dev
tags (`-dev.*`) are refused; use a dispatch. Details:
[`provider-release.md`](provider-release.md).

### 11. Onboard a Mac

```bash
curl -fsSL "https://<API host>/install.sh" | bash
```

The dev coordinator serves `install.sh` with its own URL. Because that URL is
not production, the installer writes `url = "wss://<API host>/ws/provider"`
under `[coordinator]` in `~/.config/darkbloom/provider.toml` and keeps every
other line of the file (`scripts/install.sh`, `bind_provider_coordinator`).
`darkbloom start`, `login`, `update`, the LaunchAgent and the watchdog then use
dev. A running provider keeps its old coordinator until the next `darkbloom
start`.

To move a dev Mac back to production, run the production installer
(`curl -fsSL https://api.darkbloom.dev/install.sh | bash`). It removes the
`url` line under `[coordinator]`. Then run `darkbloom start`. One Mac cannot
serve dev and production at the same time.

Add the SSH alias of the Mac to `deploy/provider-fleet/dev-inventory.txt`;
`deploy/provider-fleet/update-fleet.sh dev` runs the installer again on each
listed Mac.

### 12. Seed synthetic data

`coordinator/cmd/devnet-seed` fills an **empty** dev database with fake
accounts (`seed-<n>@example.invalid`, `did:privy:seed-<n>`), API keys,
provider machines (serials `SEED00000001`, …) with closed sessions, usage
rows, provider earnings, ledger entries and balances. It writes through the
`store` methods that the coordinator uses. It refuses to run when the `users`
table has a row, and it checks this before it runs migrations. The command is
an entry point to `coordinator/internal/command/devnetseed`.

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/devnet-seed ./coordinator/cmd/devnet-seed
gcloud compute scp /tmp/devnet-seed d-inference-dev:/tmp/devnet-seed \
  --zone=us-east4-a --project=darkbloom-dev --tunnel-through-iap
"${SSH[@]}" --command='EIGENINFERENCE_DATABASE_URL="$(sudo sed -n "s/^EIGENINFERENCE_DATABASE_URL=//p" /etc/d-inference/env)" /tmp/devnet-seed; rm -f /tmp/devnet-seed'
```

Add flags after `/tmp/devnet-seed` to change the scale:

| Flag | Default | Meaning |
|---|---|---|
| `--accounts` | `20` | Accounts (users) |
| `--keys-per-account` | `1` | API keys per account |
| `--providers` | `5` | Provider machines, owned round-robin by the accounts |
| `--sessions-per-provider` | `3` | Closed sessions per machine; each has its own `providers` row |
| `--requests-per-account` | `10` | Requests per account: one charge, one `usage` row and one provider earning each |
| `--balance-micro-usd` | `5000000` | Balance each account keeps after its requests are charged |
| `--workers` | `8` | Accounts or machines written in parallel |

Each row is a separate store write, so a large run takes a long time. Keep
`--workers` at its default while the coordinator runs.

## Verification

```bash
API=$(awk -F= '$1 == "DOMAIN" { print $2 }' deploy/gcp/dev/env-overrides)
C=$(git rev-parse HEAD); V=$(awk -F'"' '/^var LatestProviderVersion =/ { print $2 }' coordinator/api/server.go)
curl -fsS "https://$API/health" | jq -e --arg c "$C" --arg v "$V" '.status == "ok" and .version == $v and .build_commit == $c'
"${SSH[@]}" --command='sudo systemctl is-active docker caddy darkbloom-env-refresh; sudo docker ps -a --format "{{.Names}} {{.Status}}"'
scripts/smoke-dev.sh                       # /health, /v1/stats, /v1/models/catalog, install.sh
API_KEY=<dev api key> scripts/smoke-dev.sh # and one chat completion with MODEL (default Qwen3.5-9B)
```

Expected: `true`; three lines `active`; `coordinator` `Up` and one
`coordinator_fallback_<ts>` `Exited`. `scripts/smoke-dev.sh` fails until a
provider is attached and a model is registered. Its fixture checks are in
[script validation](../developer/test.md#6-scripts-and-release-integrity).

## Rollback

| Case | Action |
|---|---|
| A deploy failed a hard check | Nothing. `swap.sh` rolled back and printed `FAIL ...; rolled back to ...`. The container log is in `/var/lib/darkbloom-deploy/failed-coordinator-<UTC>.log` on the VM (root only) |
| A deploy passed, but the commit is bad | Dispatch `deploy-dev.yml` with `-f mode=rollback` (step 7), or run `deploy/gcp/dev/deploy.sh rollback` from a clean `origin/master` checkout (add `--override-pause "<reason>"` while paused). It restores the image and env file of the last verified swap. Then revert the commit on `master` |
| The first deploy is bad (no previous image) | `"${SSH[@]}" --command='sudo docker stop -t 75 coordinator && sudo docker rm coordinator'` |
| A bad reseed | Copy `/etc/d-inference/env.pre-reseed.<UTC>` back to `/etc/d-inference/env`, then deploy |
| A bad provider bundle | Deactivate the release (`scripts/admin.sh releases deactivate <version>`), then `deploy/provider-fleet/update-fleet.sh dev`; see [`provider-release.md`](provider-release.md) |

Rollback never reverts the schema; see the
[schema migration rollback rules](schema-migration.md#rollback). A teardown is
a Terraform change in darkbloom-devnet-infra.

## Troubleshooting

| Line | Cause | Fix |
|---|---|---|
| `FAIL deploys are paused or the pause state is unknown ...` | `DEV_DEPLOY_PAUSED` is not `false`, or `gh` cannot read it | Read the variable. Resume, or pass `--override-pause "<reason>"` for a manual run |
| `FAIL long queries, blocked locks or a goose lock holder; nothing changed` | A query or lock blocks migrations | Wait, then deploy again |
| `FAIL --migrate-only failed; the current coordinator still serves` | A migration of the commit fails | Read the journal of the unit (`sudo journalctl -u 'darkbloom-dev-swap-*'`). Fix the migration on `master` |
| `FAIL candidate not ready within 180 s; rolled back to ...` | The new coordinator did not start or did not report the commit | Read the saved container log on the VM |
| `FAIL the running image is not the last verified image ...` | Someone changed the container by hand | Find out why. After review, write the running image ID to `/var/lib/darkbloom-deploy/last-good-image` |
| `candidate ... is not origin/master` | `master` moved | Deploy the new head |

## DevNet checklist

These steps need a person with the right access:

1. DBLM-555: apply the darkbloom-devnet-infra roots.
2. DBLM-558: the secret values and DNS. Confirm the console host name.
3. DBLM-559: steps 1 to 6 of this page.
4. DBLM-569: after steps 1 to 6 pass, set `DEV_DEPLOY_PAUSED` to `false`, so
   that `deploy-dev.yml` deploys each eligible `master` push (step 7).
5. Ask Stripe for Redaction Jobs access on the dev account, so that account
   erasure can be tested against Stripe.
6. Enrol at least one dev Mac (step 11). Run `devnet-seed` (step 12).

## What dev does not cover

- Human approval and the deploy record: the reviewed merge is the approval,
  and the job summary and the swap journal are the record.
- APNs attestation and MDM push: placeholders until DBLM-564.
- Real users: admin access is limited to `EIGENINFERENCE_ADMIN_EMAILS`.

## Related

- [coordinator-deploy.md](coordinator-deploy.md): production. A change to a
  swap step there also changes `deploy/gcp/dev/swap.sh`.
- [`provider-release.md`](provider-release.md): release workflow, `DEV_*` secrets.
- [`../developer/build.md`](../developer/build.md): what the Dockerfile builds.
- [`../reference/configuration.md`](../reference/configuration.md): every environment variable.
- [`../provider/installation.md`](../provider/installation.md): what `install.sh` does on a Mac.
