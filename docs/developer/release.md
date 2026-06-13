# Release

## Provider bundle

The provider bundle is built and signed in CI via
`.github/workflows/release-swift.yml`.

High-level flow:

1. Build the `darkbloom` and `darkbloom-enclave` binaries.
2. Sign with the Developer ID Application certificate.
3. Notarize with Apple.
4. Compute SHA-256 hashes **after** code signing.
5. Upload to R2.
6. Register the release with the coordinator.

> **Important:** hashes must be computed after code signing, not before.
> Providers verify the hash of the signed binary during install.

Scripts:

- `scripts/build-bundle.sh` — bundle creation.
- `scripts/bundle-app.sh` — .app bundle + DMG creation.
- `scripts/install.sh` — end-user installer (served by coordinator).

## Coordinator release

Production runs on EigenCloud. Dev runs on GCP.

### Prod (EigenCloud)

```bash
git push origin master
ecloud compute app deploy d-inference
curl https://api.darkbloom.dev/health
```

See [`operations/eigencloud-to-gcp-migration.md`](../operations/eigencloud-to-gcp-migration.md) for migration notes.

### Dev (GCP)

```bash
gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=sepolia-ai
```

See `operations/dev-environment.md` for full dev environment setup.

## Version gate

`coordinator/api/server.go` contains `LatestProviderVersion`. Provider update
checks and `minProviderVersionForDesiredModels` must stay coordinated with the
uploaded bundle version.

## Console UI release

The console UI deploys automatically to Vercel on pushes to `master`.

```bash
make ui-build
```

## Release-sensitive sync points

- Provider bundle semantics: keep `scripts/build-bundle.sh`,
  `scripts/install.sh`, and `LatestProviderVersion` in sync.
- Install paths or process invocation changes must update both the CLI and the
  install flow.
- Model registry changes span coordinator registry, provider manifest code,
  `scripts/publish-model.sh`, and the console UI.
