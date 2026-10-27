# Add-on hold IPC reference

> Last updated: 2026-10-27

The local `hold.v1` contract between the provider and add-ons such as the
Darkbloom Sandbox: socket, framing, operations, fields, errors, peer checks and
files. Source: `provider-swift/Sources/ProviderCore/Addon/AddonIPC.swift`
(`AddonIPC`) and `provider-swift/Sources/ProviderCore/Addon/AddonIPCServer.swift`
(`AddonIPCServer`). Behavior is explained in [add-on hold](../architecture/addon-hold.md).

## Files

All paths are in the install directory's `runtime` directory, `0700` and owned
by the provider's user (`AddonHoldPaths`, `AddonRuntimeDirectory` in
`provider-swift/Sources/ProviderCore/Addon/AddonHoldPaths.swift`). Production
builds use `~/.darkbloom/runtime`; dev and staging builds use their own install
directory.

| File | Owner | Purpose |
|---|---|---|
| `addon.sock` | provider, `0600` | `AF_UNIX` stream socket. A stale socket is replaced; a live one is never taken over |
| `addon-hold.json` | provider, `0600` | Active holds (`schema: 1`, `holds[]` with `hold_id`, `addon`, `vm_bytes`, `state`, `since_ms`, `lease_seconds`, `lease_expires_at_ms`); absent when not held |
| `ownership.lock` | add-on | Held exclusively (`flock`) while any lease or VM exists. The provider only probes it with a non-blocking shared lock; a missing file is free and any other probe failure counts as held |

`DARKBLOOM_ADDON_SOCKET` overrides the socket path for tests. The socket's
directory then holds all three files, matching add-ons, which keep
`ownership.lock` beside the socket; see [configuration](configuration.md#add-on-hold).

## Framing

| Rule | Value |
|---|---|
| Message | One JSON object per line, terminated by `\n` |
| Size | At most 8 KiB (`maximumMessageBytes = 8 * 1024`) before the newline; a longer line gets one `invalid_request` and the connection closes |
| Responses | Exactly one line per request, in order; keys are exactly those listed below |
| Connections | Several requests per connection; at most 8 connections (`maximumConnections`); closed after 300 s idle (`idleTimeout`) |
| Unknown request keys | Ignored |

## Operations

Every request carries `"v": 1` and `op`. A `v` other than 1 gets
`unsupported_version` before the operation is checked.

| `op` | Request fields | Success response |
|---|---|---|
| `hello` | — | `{"v":1,"ok":true,"capabilities":["hold.v1"],"provider_version":"x.y.z"}` |
| `hold` | `addon` (string, must equal the verified signer), `vm_bytes` (non-negative integer), `lease_seconds` (30–600) | `{"v":1,"ok":true,"hold_id":"<uuid>","state":"draining"\|"held","since_ms":N,"lease_expires_at_ms":N}` |
| `status` | `hold_id` | `{"v":1,"ok":true,"state":"draining"\|"held"\|"released"\|"expired","since_ms":N,"lease_expires_at_ms":N}` |
| `renew` | `hold_id`, `lease_seconds` (30–600) | `{"v":1,"ok":true,"state":…,"lease_expires_at_ms":N}` |
| `release` | `hold_id` | `{"v":1,"ok":true,"state":"released"}` |

| Semantics | Rule |
|---|---|
| Idempotency | One active hold per add-on. A repeated `hold` returns the same `hold_id`, renews the lease and records the new `vm_bytes` |
| Lease | `renew` and a repeated `hold` set the expiry to now + `lease_seconds` (wall clock, Unix milliseconds) |
| Ended holds | The provider remembers the last 32 ended holds (`AddonHoldBook.endedLimit`): `status` and `renew` report `released` or `expired`, `release` answers `released`. An ended hold is never revived |
| Expiry | A lease that expires while `ownership.lock` is held keeps the hold (`status` shows a past `lease_expires_at_ms`); it ends once the lock is free |
| Restart | A provider restart keeps active holds and their IDs; ended-hold history is not kept |
| Scope | A peer sees and changes only holds of its own identifier; others are `not_found` |

## Errors

`{"v":1,"ok":false,"error":"<code>"}`

| `error` | When |
|---|---|
| `unauthorized` | Peer failed verification (the connection then closes), or `addon` differs from the verified identifier |
| `unsupported_version` | `v` is a number other than 1 |
| `invalid_request` | Not a JSON object, missing or wrongly typed field, unknown `op`, lease out of range, oversized line |
| `not_found` | Unknown `hold_id`, or a hold of another add-on |
| `unavailable` | The provider is stopping, a model switch owns admission, the handler did not answer within 30 s, or the connection limit was reached |

## Peer verification

Every request is checked, so a peer that executes other code after
connecting fails (`AddonPeerPolicy.authenticate` in
`provider-swift/Sources/ProviderCore/Addon/AddonPeerPolicy.swift`):

1. The socket's `LOCAL_PEERTOKEN` audit token must have the provider's
   effective UID.
2. The token, not a PID or path, selects the running code
   (`SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit`).
3. The code must satisfy `anchor apple generic and identifier
   "io.darkbloom.sandbox" and certificate 1[field.1.2.840.113635.100.6.2.6]
   and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate
   leaf[subject.OU] = "SLDQ2GJ6TL"`, carry team `SLDQ2GJ6TL` and identifier
   `io.darkbloom.sandbox`, and be signed with the hardened runtime.

DEBUG builds additionally accept one identity named by
`DARKBLOOM_ADDON_DEV_IDENTITY` (`TEAMID:identifier`, for example
`P7373SVQX6:io.darkbloom-test.sandbox`), requiring that team and identifier
from an Apple-anchored certificate plus the hardened runtime. Release builds
compile without it.

The provider and add-on run as the same user and can read each other's files;
the socket and lock coordinate them and are not a boundary against that user.
See [threat model](../threat-model.yaml) `TB-012`.

## Related

- [Add-on hold](../architecture/addon-hold.md)
- [Protocol busy fields](protocol-messages.md#add-on-hold-busy-fields)
- [`darkbloom addon`](../provider/cli-reference.md#darkbloom-addon)
