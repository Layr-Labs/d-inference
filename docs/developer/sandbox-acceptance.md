# Prepare isolated physical sandbox acceptance

> Last updated: 2026-09-13 · commit `5c25e79a2`

Use the real coordinator, PostgreSQL store, consumer API authentication and
dedicated host WebSocket on an authorized test Mac. The fixture tool creates
private test credentials and launch environments; it does not simulate the API
or start services during seeding.

The coordinator/database may remain on the primary Mac while a reverse SSH
API tunnel terminates on `127.0.0.1` on the test Mac. Keep the same API port and
absolute CLI/helper/fixture paths on both machines. Copy only `fixture.json`,
`consumer-env.json`, `consumer-config.json` and `host-token` for remote client
and host use; keep the database URL and `coordinator-env.json` on the primary
Mac. No SQL tunnel is needed in that topology.

## Prerequisites

- An explicitly authorized nonproduction test Mac and the source checkout used to build its artifacts.
- A qualified signed host daemon, pinned Lume, signed guest release, prepared base image, encrypted APFS VM storage and initialized capacity directory. Host installation, mode changes and VM qualification remain separate operator steps in [release validation](../../sandbox-macos/Resources/RELEASE_VALIDATION.md#prepare-a-dedicated-host).
- An empty dedicated PostgreSQL database named `darkbloom_sandbox_acceptance_<suffix>`, with a suffix of 1–24 lowercase letters, digits or underscores. Create it from `template0`; the fixture refuses existing user relations, functions and types before running migrations.
- A private, owner-only file containing the database URL. It must use a loopback IP literal, explicit port, username/password and only `sslmode=disable`. A database on another machine requires an explicitly managed private tunnel terminating on loopback. Never use a production proxy or production credentials.
- Separate absolute paths for the coordinator binary, consumer CLI and new private fixture directory on the test Mac. Select an unused unprivileged loopback API port.

## Steps

1. Build the real entrypoints from the selected checkout. `OUTPUT_BIN` is an existing private output directory outside the checkout.

   ```sh
   go build -o "$OUTPUT_BIN/coordinator" ./coordinator/cmd/coordinator
   go build -o "$OUTPUT_BIN/darkbloom-sandbox" ./coordinator/cmd/darkbloom-sandbox
   go build -o "$OUTPUT_BIN/sandbox-acceptance-fixture" ./coordinator/cmd/sandbox-acceptance-fixture
   ```

   For a different machine, build for its OS/architecture and transfer the artifacts through the authorized operator channel. The coordinator must include `EIGENINFERENCE_BIND_HOST` support; an older binary is unsuitable for this fixture.

2. Seed the explicitly selected empty database. This step creates one ordinary consumer through `CreateUser`, mints an account-owned 24-hour API key through `CreateAPIKey`, and generates a separate random host credential. It clears inherited environment settings before opening PostgreSQL.

   ```sh
   "$OUTPUT_BIN/sandbox-acceptance-fixture" seed \
     --directory "$FIXTURE_DIR" --database-url-file "$DATABASE_URL_FILE" \
     --port 18080 --base-image "$QUALIFIED_BASE_IMAGE" \
     --coordinator "$OUTPUT_BIN/coordinator" \
     --client "$OUTPUT_BIN/darkbloom-sandbox" --confirm-disposable
   ```

   No token is printed. `coordinator-env.json`, `consumer-env.json` and `host-token` contain private material. `fixture.json` describes the completed enrollment; `consumer-config.json` is the credential-free configuration expected by the real acceptance harness. Do not source the JSON files as shell scripts. A partial failure is not launchable; investigate it and use a new disposable database/directory rather than resetting an existing one.

3. Start the real coordinator in a dedicated operator session when ready. The launcher verifies the generated environment and replaces itself with `cmd/coordinator`, without inheriting cloud, MDM, Privy, Datadog, admin, release or database settings.

   ```sh
   "$OUTPUT_BIN/sandbox-acceptance-fixture" run-coordinator \
     --directory "$FIXTURE_DIR" --confirm-start
   ```

   It binds `127.0.0.1:18080`, uses durable PostgreSQL and the normal cache/store stack, enables sandbox service/admission only for the generated account, and keeps warm-pool, base-rewards and prompt-sidecar work disabled. No admin key is seeded. The local trust-revocation journal remains inside the fixture directory. Confirm the actual listening address from the process log and OS listener inventory before continuing.

4. Connect the qualified host daemon using `fixture.json`'s `host_id` and `host_websocket_url`, plus the private `host-token` file. The operator supplies the signed binaries, guest release, base image, storage/capacity paths and capacity limits.

   ```sh
   "$SIGNED_DAEMON" serve --coordinator ws://127.0.0.1:18080/ws/sandbox-host \
     --host-id "$FIXTURE_HOST_ID" --token-file "$FIXTURE_DIR/host-token" \
     --allow-insecure-loopback --lume "$PINNED_LUME" \
     --guest-release "$SIGNED_GUEST_RELEASE" \
     --storage "$VM_STORAGE" --capacity-dir "$CAPACITY_DIR" \
     --base-images "$QUALIFIED_BASE_IMAGE" --max-cpu 8 --max-memory-gib 16
   ```

   This command does not activate a draining/idle host. Follow the host-mode procedure in the release guide; the capacity store must be in `sandbox_dedicated` mode and actual guest qualification must pass. Do not bypass machine-ownership locks or infer readiness from WebSocket registration alone.

5. Exercise account-authenticated routes, then run the existing physical consumer harness without exposing the key in arguments.

   ```sh
   "$OUTPUT_BIN/sandbox-acceptance-fixture" run-client \
     --directory "$FIXTURE_DIR" --confirm-start -- list

   "$OUTPUT_BIN/sandbox-acceptance-fixture" run-acceptance \
     --directory "$FIXTURE_DIR" --confirm-start \
     --python /usr/bin/python3 \
     --harness "$CHECKOUT/sandbox-macos/Scripts/test-sandbox-live.py" \
     --output "$NEW_ACCEPTANCE_EVIDENCE"
   ```

   Workspace exhaustion remains opt-in through `--workspace-exhaustion`. The fixture preserves real authorization, routes and runtime boundaries; it does not add fake readiness responses or grant service/admin roles. The client launcher fixes the endpoint and rejects global endpoint overrides before the subcommand.

6. Complete cleanup through the consumer lifecycle and verify the host inventory. Stop the host/coordinator processes and remove only this fixture's disposable database and private directory after every created sandbox is confirmed deleted. Keep logs and acceptance evidence separately; API terminal state does not prove physical VM removal.

## Verify

- Confirm the coordinator listener is loopback only and the startup log reports the expected address.
- Missing/invalid consumer credentials must fail; the seeded API key must reach the actual account-scoped routes. A healthy `/health` response alone is insufficient.
- Confirm host registration uses its separate token and that the enrolled account can create, execute, transfer files, recover and delete through the acceptance harness.
- Check the command replay and partial-transfer cases, then `natural-expiry.json`: the second VM stays ready and a command must be observed running in the lease's final twelve seconds. Command timeout and expiry can race because command deadlines must fit the lease; no Stop/Renew or clock change is used in that case.
- Retain the acceptance summary and independent physical inventory/cleanup proof. Local fixture unit tests do not establish VM isolation or performance.
- Read `summary.json`'s `not_covered` list before assessing readiness. The fixture enrolls one consumer; separate-account denial requires a second independently seeded account/key and working positive controls for both owners. Broker crash/reboot, scheduler respawn and paired guest build performance are separate campaigns in the [release validation guide](../../sandbox-macos/Resources/RELEASE_VALIDATION.md).

## Troubleshooting

| Symptom | Action |
|---|---|
| Database rejected before migrations | Check the explicit loopback address, database naming rule, private-file mode and empty database requirement. Do not point it at an existing application database. |
| Fixture incomplete | Do not launch from it; inspect the failed preparation and create a new disposable fixture. |
| API key expired | The test key lasts 24 hours; prepare a fresh fixture. |
| Authenticated create returns no capacity | Verify dedicated host mode, signed guest readiness, image availability and physical capacity. |
| Coordinator environment rejected | Restore the generated fixture files; the launcher rejects unexpected credentials and changed binding/auth settings. |
| No bind-host support in the binary | Rebuild `cmd/coordinator` from the source containing `ListenAddress`; do not launch an all-interface workaround. |

## Related

- [Configuration](../reference/configuration.md)
- [Sandbox API contract](../reference/sandbox-api.md)
- [Sandbox CLI](../consumer/sandbox-cli.md)
- [Physical release validation](../../sandbox-macos/Resources/RELEASE_VALIDATION.md)
