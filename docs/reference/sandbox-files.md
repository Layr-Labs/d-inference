# Sandbox file transfer contract

> Last updated: 2026-09-13 · commit `453b37667`

This reference defines bounded workspace file transfers through the sandbox API
and its host WebSocket. File bytes pass through coordinator memory and are not
stored in coordinator command records. See [sandbox access and lifecycle](sandbox-api.md)
before using these routes.

## Consumer routes

All routes use account API-key or Privy authentication, and every path is
relative to the sandbox workspace; absolute paths, empty components, `.` and
`..` are rejected. The source is `coordinator/api/sandbox_routes.go`
(`registerSandboxFileRoutes`) and `coordinator/api/sandbox_files.go`.

| Method and route | Request | Response / handler |
|---|---|---|
| `POST /v1/sandboxes/{sandboxID}/files/directories` | JSON `{path}` | 200 `{request_id}`; `handleSandboxFileMkdir` |
| `POST /v1/sandboxes/{sandboxID}/files/uploads` | JSON `{transfer_id, path, size, sha256}`; client-selected UUID, total bytes, lowercase full-file SHA-256 | 200 transfer metadata; `handleSandboxUploadBegin` |
| `PUT /v1/sandboxes/{sandboxID}/files/uploads/{transferID}/chunks?offset=N` | Raw `application/octet-stream`, nonempty and at most 512 KiB | 200 transfer metadata with next offset; `handleSandboxUploadChunk` |
| `GET /v1/sandboxes/{sandboxID}/files/uploads/{transferID}` | — | 200 transfer metadata; `handleSandboxUploadStatus` |
| `POST /v1/sandboxes/{sandboxID}/files/uploads/{transferID}/commit` | No body | 200 committed transfer metadata after the guest verifies size/hash and publishes without overwriting an existing destination; `handleSandboxUploadCommit` |
| `DELETE /v1/sandboxes/{sandboxID}/files/uploads/{transferID}` | No body | 200 `{request_id, transfer_id, state: "aborted"}`; already committed returns 409 `upload_already_committed` and preserves the file; `handleSandboxUploadAbort` |
| `GET /v1/sandboxes/{sandboxID}/files?path=P&offset=N&length=N&version=V` | Relative path, optional offset (default 0), optional length (default/maximum 524288); version is required after offset 0 | 200 raw octet-stream with integrity headers; 409 `file_changed` on a changed revision; `handleSandboxFileDownload` |

Transfer metadata contains `request_id`, `transfer_id`, `state`, `offset`, `size`
and `sha256`; states are `uploading`, `committed` and `aborted`. Begin/chunk/commit
and mkdir require enabled admission and account enrollment. Status, abort and
download remain accessible to the authenticated owner while admission drains.
File operations require a live `ready` sandbox whose lease is unexpired; stopped
or terminating VMs cannot serve guest files.

| Download header | Meaning | Code |
|---|---|---|
| `X-Sandbox-File-Size` | Total file length, not the returned chunk length | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |
| `X-Sandbox-File-Offset` | Offset of the returned chunk | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |
| `X-Sandbox-Chunk-SHA256` | Lowercase SHA-256 of the exact returned bytes | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |
| `X-Sandbox-File-Version` | Opaque 64-hex revision token to supply as `version` on every later chunk | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |
| `Content-Length` | Returned chunk length; zero is valid at EOF | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |
| `Cache-Control: no-store` | File responses must not be cached | `coordinator/api/sandbox_files.go` (`relaySandboxFile`) |

Retrieve files after their producing commands finish. Preserve the first chunk's
version and send it with every later request. The guest checks file identity,
size and modification/change times before and after reading; a changed revision
returns 409 `file_changed`, and the client must discard partial output. The
coordinator also rejects a host response carrying a different requested version
(`coordinator/sandboxcontrol/files.go`, `handleFileResult`).

## Host wire schema

Both message directions use the ordinary versioned sandbox envelope with host
ID, connection epoch, sequence and payload. The coordinator supplies request
identity and allocation scope; consumer JSON cannot supply either authority.

| Message | Required payload fields | Optional payload fields | Code |
|---|---|---|---|
| `sandbox_file_operation` | `request_id` UUID, `scope` `{sandbox_id,generation,fencing_token}`, `operation` | `transfer_id`, `path`, `offset`, `size`, `sha256`, `data` (canonical base64), `version` | `coordinator/protocol/sandbox_files.go` (`SandboxFileOperationPayload`); `sandbox-macos/Sources/SandboxCore/SandboxFileProtocol.swift` (`SandboxWireFileOperation`) |
| `sandbox_file_result` | `request_id`, `scope`, `operation`, `success` | `error_code`, `transfer_id`, `state`, `offset`, `size`, `sha256`, `data`, `version` | `coordinator/protocol/sandbox_files.go` (`SandboxFileResultPayload`); `sandbox-macos/Sources/SandboxCore/SandboxFileProtocol.swift` (`SandboxWireFileResult`) |
| Host capabilities | Existing capability fields | `supports_files` boolean; absent means unsupported | `coordinator/protocol/sandbox_types.go` (`SandboxHostCapabilities`), `sandbox-macos/Sources/SandboxCore/SandboxControlProtocol.swift` (`SandboxWireHostCapabilities`) |

| Operation | Permitted request fields beyond identity/scope/operation | Successful result fields beyond identity/scope/operation/success |
|---|---|---|
| `upload_begin` | `transfer_id`, `path`, `size`, `sha256` | `transfer_id`, `state`, `offset`, `size`, `sha256` |
| `upload_chunk` | `transfer_id`, `offset`, `data` | `transfer_id`, `state`, `offset`, `size`, `sha256` |
| `upload_status` | `transfer_id` | `transfer_id`, `state`, `offset`, `size`, `sha256` |
| `upload_commit` | `transfer_id` | `transfer_id`, `state`, `offset`, `size`, `sha256` |
| `upload_abort` | `transfer_id` | `transfer_id`, `state: "aborted"` |
| `download` | `path`, `offset`, `size` (requested chunk length), `version` (optional only at offset 0) | `data`, `offset`, `size` (total file length), `sha256` (chunk digest), `version` |
| `mkdir` | `path` | None |

The closed field sets and digest/size constraints are enforced by
`coordinator/protocol/sandbox_files.go` (`ValidateSandboxFileOperation`,
`ValidateSandboxFileResult`) and the Swift request codec
`sandbox-macos/Sources/SandboxCore/SandboxControlCodec.swift` (`decodeCoordinatorMessage`).
Failures carry only `error_code` and optionally the matching transfer ID; no
file bytes or successful-transfer metadata accompany a failure.
`version` is valid only for downloads and must be lowercase 64-hex text.

## Bounds and uncertain outcomes

| Contract | Bound / behavior | Code |
|---|---|---|
| Chunk bytes | 512 KiB before base64 | `coordinator/protocol/sandbox_files.go` (`SandboxMaximumFileChunkBytes`) |
| File size | At most the allocation's workspace size, with a protocol maximum of 50 GiB | `coordinator/sandboxcontrol/files.go` (`FileOperation`), `coordinator/protocol/sandbox_files.go` (`SandboxMaximumFileBytes`) |
| Paths | At most 4096 UTF-8 bytes and 255 bytes per component | `coordinator/protocol/sandbox_files.go` (`ValidSandboxWorkspacePath`) |
| Concurrent relays | 32 process-wide, 8 per account | `coordinator/sandboxcontrol/files.go` (`maximumPendingFileRequests`, `maximumPendingFilesPerAccount`) |
| Relay lifetime | 30 seconds including store lookup and queued host writes; cancellation/disconnect retires pending state | `coordinator/sandboxcontrol/files.go` (`FileRelayTimeout`, `FileOperation`), `coordinator/sandboxhost/registry.go` (`Session.Send`) |
| Authority | Result must match exact host connection, request ID, operation, scope and transfer; authority is checked again before returning to the consumer | `coordinator/sandboxcontrol/files.go` (`handleFileResult`, `FileOperation`) |
| Coordinator retention | File bytes are transient; no file-data database writes or command execution are used by the relay | `coordinator/sandboxcontrol/files.go` (`FileOperation`) |
| Timeout | 504 `sandbox_file_timeout`; a dispatched mutation may have completed. Inspect the same transfer ID before retrying or committing again | `coordinator/api/sandbox_files.go` (`writeSandboxFileError`) |
| Relay full | 429 `sandbox_file_busy`, `Retry-After: 1` | `coordinator/api/sandbox_files.go` (`writeSandboxFileError`) |
| Unsupported host | 503 `sandbox_files_unavailable`, before any file dispatch | `coordinator/sandboxcontrol/files.go` (`FileOperation`) |
