# Storage

The coordinator supports two storage backends.

| Backend | Use case | Path |
|---|---|---|
| `MemoryStore` | Development / default | `coordinator/store/memory.go` |
| `PostgresStore` | Production target | `coordinator/store/postgres.go` |

## In-memory store

The default. Provider state is lost on coordinator restart. Use this for local
development and simple deployments.

## Postgres store

Persistent store for production. Tables include:

- `api_keys`
- `usage`
- `payments`
- `balances`
- `ledger_entries`

The store interface is in `coordinator/store/interface.go`.

## Provider local storage

Providers cache:

- downloaded model weights in the local filesystem cache,
- encrypted KV-cache files in `~/Library/Caches/darkbloom/kv/`,
- the Secure-Enclave-wrapped KEK in the macOS Keychain,
- local API tokens in `~/.darkbloom/local_token`.

See [`reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) for the cache on-disk layout and cryptography.
