# Run and cancel sandbox commands

> Last updated: 2026-09-13 · commit `453b37667`

Use the private-alpha sandbox API to allocate a workspace, run an exact command,
read its result, and release its capacity. This workflow requires a qualified
sandbox host and an operator-enabled service.

## Prerequisites

- An account API key or Privy session enrolled in sandbox private-alpha admission.
- The coordinator base URL, supported base-image ID and workspace size supplied by the operator.
- A configured host that advertises ready sandbox capacity. Configuring the HTTP service alone does not qualify host isolation.
- Review the [sandbox command retention contract](../reference/sandbox-api.md#command-payload-retention): command inputs and outputs are retained until eligible for redaction, then status remains available with explicit expiry metadata.

## Steps

1. Create a sandbox with `POST /v1/sandboxes`. Set a fresh UUID in `Idempotency-Key` and send the operator-provided image/resources. Preserve the key when retrying this request.

   ```json
   {"base_image_id":"macos-tahoe-v1","cpu_count":4,"memory_gib":8,"workspace_gib":25}
   ```

   The 202 response contains `sandbox.id` and `operation.id`. Poll `GET /v1/sandbox-operations/{operationID}` until its state is `ready`, then retrieve `GET /v1/sandboxes/{sandboxID}`. Inspect a `failed` operation before submitting new work.

2. To supply source files, create relative workspace directories, begin an upload with a transfer UUID and the file's size/SHA-256, send raw chunks at the returned offset, then commit. Follow the [file-transfer route contract](../reference/sandbox-files.md#consumer-routes). Keep the transfer ID when retrying; a timeout requires a status lookup before resending bytes.

3. Run `POST /v1/sandboxes/{sandboxID}/commands` with another UUID in `Idempotency-Key` and the exact argument vector. Commands default to `/workspace`; `working_directory` may name a safe directory beneath it. The example prints a message without invoking a shell.

   ```json
   {"arguments":["/usr/bin/printf","hello from the sandbox\n"],"timeout_seconds":60}
   ```

   Keep `command.id` from the response. Poll `GET /v1/sandboxes/{sandboxID}/commands/{commandID}` for state, exit code and output. `GET /v1/sandboxes/{sandboxID}/commands?limit=100` returns recent command metadata.

4. To stop an unwanted command, call `POST /v1/sandboxes/{sandboxID}/commands/{commandID}/cancel` without a body. Poll until `cancellation_pending` is false before starting another command. A command that already completed preserves its result. Retrieve produced files through the bounded download route after the command finishes, validating each returned chunk against its SHA-256 header. Preserve `X-Sandbox-File-Version` from the first response and supply it as the `version` query on every later chunk. Discard partial downloads after 409 `file_changed`.

   If interruption stopped the VM, use `POST /v1/sandboxes/{sandboxID}/start` with a new idempotency UUID after cleanup finishes. Wait for the start operation to reach `ready` before commands or downloads. This preserves the workspace and original lease deadline; `renew` only extends the deadline.

5. When finished, call `DELETE /v1/sandboxes/{sandboxID}` with a new UUID in `Idempotency-Key`. Preserve that key across retries. Poll the sandbox until its state is `deleted`; a 202 response records cleanup intent and does not itself prove cleanup finished.

## Verify

The command should reach `succeeded` with the expected exit code/output. The
sandbox should reach `deleted` after cleanup. `stopped` still reserves capacity.
See the [durable execution contract](../reference/sandbox-api.md#durable-execution-semantics)
for exact deadlines, states and replay behavior.

## Troubleshooting

| Symptom | Action |
|---|---|
| 403 `sandbox_access_required` | Request private-alpha enrollment for the account that owns the key. |
| 503 `sandbox_draining` | Admission is paused; retrieve results and cancel/delete existing work. |
| 429 with `Retry-After` | Retry after the stated delay using the original idempotency key. |
| 409 when starting a command | Inspect active commands and operations; pending host cleanup blocks replacement work. |
| Cleanup stays pending after disconnect | Keep the original resource and operation IDs; the coordinator retries when the host reconnects. |

## Related

- [Sandbox API reference](../reference/sandbox-api.md)
- [Authentication](authentication.md)
- [Runtime requirements](../../sandbox-macos/README.md)
