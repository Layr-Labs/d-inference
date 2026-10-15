# Digest-only cache policy patch

Apply `digest-only.patch` against the source pinned in `base-pin.json`. Only
`VerifiedCheckpoint.File.digest()` changes. Existing signatures, full payload
and aggregate hashing, file identity checks, descriptor reuse, configuration/
manifest pins, caps, model entrypoints and payload-loading reads are unchanged.

The existing fresh descriptor has normal caching and exclusive ownership during
verification. The digest enables `F_NOCACHE` before any checksum read and reuses
one `Data` buffer of at most 4 MiB. Each exact filled prefix enters SHA256 once.
Empty files still produce the empty SHA256; final partial blocks never hash
stale buffer suffixes. `read` retains its interrupted/short-read handling and the
post-loop `checkUnchanged` is preserved.

Every successful return follows a checked `F_NOCACHE=0` operation. On a read or
identity error the catch attempts restoration and rethrows that original error
unchanged even if cleanup fails. If the normal success-path restoration fails,
the function throws that restoration error and retries restoration best-effort
in catch; it cannot publish a verified checkpoint. Constructor failure releases
the owned descriptor. This is the parent-requested narrow error policy; it does
not add a generic cleanup receipt or descriptor-policy API.

The source basis is `checkpoint-nocache-source-draft/RECOMMENDATION.md` and its
manifest `75f1a16f9cb13adbc3e7f9f28461f7a2a1a9a1d1c1062c40327fd9fbda214f78`.
Apple XNU commit `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` anchors:

- [Per-open-file flag toggle, no eviction](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_descrip.c#L3600).
- [Translation to IO_NOCACHE](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_vnops.c#L1133).
- [Discard only newly read ranges, preserve valid cached ranges](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_cluster.c#L5172).
- [Direct path can serve existing cache hits](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_cluster.c#L5574).

This reduces newly retained checksum data; it does not evict old cached pages,
guarantee an OS memory bound, change read-ahead/global policy, or authorize a
previously refused load. The actual-free gates and existing floors still apply.

`check_source.py` only verifies scope, byte recipes and error-path ordering. It
does not compile Swift, exercise fcntl, read a checkpoint or run a model. Root
owns the existing actual tiny `VerifiedCheckpoint` constructor fixture and
native build/regression. No new test framework or runtime claim is added here.
