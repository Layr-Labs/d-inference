# Use the sandbox command-line client

> Last updated: 2026-09-13 · commit `453b37667`

Use `darkbloom-sandbox` to allocate a private-alpha sandbox, upload source, run
commands, download results, and delete the allocation. This standalone Go client
runs on macOS and Linux and does not load the inference provider.

## Prerequisites

- Go from the repository toolchain, or a built `darkbloom-sandbox` client.
- An account enrolled in sandbox private-alpha admission, with a qualified host and base-image ID supplied by the operator.
- `DARKBLOOM_API_KEY` set to the account API key. Set `DARKBLOOM_API_URL` when using a different coordinator; HTTPS is required.

The client reads credentials from the environment and does not accept an API-key
command-line flag. Sandbox admission and the data contract are defined in the
[API reference](../reference/sandbox-api.md).

## Steps

1. Build the standalone client from the repository root, then inspect its help.

   ```bash
   go build -o /tmp/darkbloom-sandbox ./coordinator/cmd/darkbloom-sandbox
   /tmp/darkbloom-sandbox --help
   ```

2. Create a sandbox with the operator's base image. Creation waits until ready by default; `--wait=false` returns the accepted operation immediately.

   ```bash
   /tmp/darkbloom-sandbox --json create --image macos-tahoe-v1
   ```

   Save the returned `sandbox.id` in `SANDBOX_ID` for the commands below. `list` shows recent allocations; `inspect "$SANDBOX_ID"` shows current state and lease expiry.

3. Create a workspace directory and upload source. Workspace paths are relative.

   ```bash
   /tmp/darkbloom-sandbox mkdir "$SANDBOX_ID" src
   /tmp/darkbloom-sandbox upload "$SANDBOX_ID" ./main.swift src/main.swift
   ```

   Save the printed transfer ID. After interruption, inspect it with `upload-status "$SANDBOX_ID" "$TRANSFER_ID"`, or resume the same source/path with `upload --transfer-id "$TRANSFER_ID" "$SANDBOX_ID" ./main.swift src/main.swift`. The client hashes the complete source and reconciles the guest's offset after an uncertain chunk acknowledgement. `upload-abort` abandons an unfinished upload; a committed upload returns `upload_already_committed` and keeps its file.

4. Execute exact arguments after `--`. Commands default to `/workspace`; explicit directories must stay beneath it.

   ```bash
   /tmp/darkbloom-sandbox exec --cwd /workspace/src --timeout 300 "$SANDBOX_ID" -- /usr/bin/swiftc main.swift -o program
   /tmp/darkbloom-sandbox exec "$SANDBOX_ID" -- /workspace/src/program
   ```

   Execution waits for completion and prints stdout/stderr by default. Use `--wait=false` for an asynchronous command ID, then `job status`, `job logs`, or `job cancel` with the sandbox and command IDs. `job list "$SANDBOX_ID"` lists recent command metadata. Interrupting a waiting client requests cancellation for an accepted command; inspect `cancellation_pending` until cleanup is confirmed. Explicit environment values use repeated `--env NAME=VALUE`; the client does not copy its own environment into a job.

5. Download a result to a new local path after the producing command finishes.

   ```bash
   /tmp/darkbloom-sandbox download "$SANDBOX_ID" src/program ./program-from-sandbox
   ```

   The client checks chunk hashes, pins one file revision across chunks, and publishes the complete local file atomically without overwriting an existing path. Corrupt or changed downloads discard their staging file. Upload publication also refuses to overwrite an existing workspace path.

6. Delete the sandbox when finished. The command waits for `deleted`, which confirms coordinator capacity release.

   ```bash
   /tmp/darkbloom-sandbox delete "$SANDBOX_ID"
   ```

   `stop` stops execution while retaining the workspace and reservation. Run `start "$SANDBOX_ID"` to resume the same workspace before the lease expires, after pending command cleanup finishes. Start keeps the original deadline; `renew` extends the lease without starting a stopped VM. Use `delete` to release the allocation.

## Verify

The executed command returns its successful output or a nonzero process status.
The downloaded bytes should match the expected artifact, and `inspect` should
report `deleted` after cleanup. Use global `--json` before the command for one
machine-readable result on stdout.

| Client check | Source |
|---|---|
| HTTPS, local HTTP opt-in, environment credentials | `coordinator/cmd/darkbloom-sandbox/config.go` (`parseConfig`) |
| Exact argv and one idempotency key | `coordinator/cmd/darkbloom-sandbox/commands.go` (`execute`), `coordinator/cmd/darkbloom-sandbox/app.go` (`mutationKey`) |
| Upload hash, identity and offset recovery | `coordinator/cmd/darkbloom-sandbox/upload.go` (`upload`) |
| Download version, checksum and bounds | `coordinator/cmd/darkbloom-sandbox/download.go` (`readDownloadChunk`) |
| Local atomic publication without overwrite | `coordinator/cmd/darkbloom-sandbox/local_files.go` (`localDownload.publish`) |
| Offline workflow fixture | `coordinator/cmd/darkbloom-sandbox/testdata/workflow.json`, `coordinator/cmd/darkbloom-sandbox/workflow_test.go` (`TestOfflineConsumerWorkflowResumesUploadAndPinsDownload`) |

## Troubleshooting

| Symptom | Action |
|---|---|
| Lifecycle or exec request failed with an uncertain outcome | Retry the same command with the printed global `--idempotency-key UUID`. The client does not retry execution with a new key. |
| Upload response was lost | Resume with the same transfer ID, local file and workspace path. |
| `file_changed` or checksum failure | Discard partial results, finish all writes, and start a new download. |
| Local output already exists | Choose a new path; the client never overwrites it. |
| Command payload expired | Outcome metadata remains available; old stdout/stderr were redacted. Reusing the original idempotency key returns that same expired result and does not rerun the job. |
| Start fails with `runtime_cleanup_failed` | The VM has not proved it stopped. The allocation remains `failed` and reserves capacity; request deletion and wait for confirmed cleanup. |
| Sandbox is stopped | Run `start "$SANDBOX_ID"` while the lease is active to regain command and file access. Start needs a connected host that supports resume and open admission. |
| Admission is paused | Inspect/cancel commands and delete existing allocations; new work remains closed. |
| Testing a local coordinator over HTTP | Pass both `--api-url http://127.0.0.1:PORT` and `--allow-insecure-localhost`. The exception is limited to loopback. |

## Related

- [Sandbox API workflow](sandbox-commands.md)
- [Sandbox file transfer contract](../reference/sandbox-files.md)
- [Configuration](../reference/configuration.md#sandbox-private-alpha)
