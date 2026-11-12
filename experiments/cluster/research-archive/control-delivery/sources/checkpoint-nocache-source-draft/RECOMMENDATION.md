# Limit checkpoint checksum cache pollution

2026-09-14. Source research only. No checkpoint bytes, constructor outputs,
native/compiler/SSH jobs or cache operations were accessed or executed here.

Use **`F_NOCACHE` only inside `VerifiedCheckpoint.File.digest()`**, on its existing
owned descriptor, and restore normal caching before returning the digest. Keep
the complete single-pass SHA256 and aggregate verification unchanged. This is
a practical prevention mechanism for newly fetched checksum data; it is not a
targeted purge of pages already in the file cache.

The installed macOS26.5 SDK `fcntl(2)` manual defines nonzero as disabling data
caching and zero as enabling it; `sys/fcntl.h` defines `F_NOCACHE=48` for the
descriptor. Apple also publishes the [manual online](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html).
The SDK documentation does not promise eviction or an exact memory bound.

The pinned Apple XNU source at commit
`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea` explains the observed limitation:

- [`fcntl` handling](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_descrip.c#L3600)
  sets or clears `FNOCACHE` in the open-file flags. This branch has no cache
  eviction operation. Duplicated descriptors share the open-file state, so a
  `dup` is not an isolated caching policy.
- [`vn_read`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_vnops.c#L1133)
  translates that flag to `IO_NOCACHE` before filesystem dispatch.
- [`cluster_read_direct`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_cluster.c#L5574)
  checks existing cached pages first. The fallback copy path identifies missing
  pages, reads them, and discards those newly fetched pages under `IO_NOCACHE`;
  already-valid pages are released without changing their state. It also
  disables its ordinary read-ahead for this policy. See the
  [missing-page scan](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_cluster.c#L4980)
  and [post-read handling](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_cluster.c#L5172).

These source paths support avoiding new retained read-cache pages, including a
copy fallback when direct IO is unsuitable. They do not establish the exact
implementation of the running kernel/APFS build, guarantee recovery of old
cache, or bound temporary IO/VM memory. Root's reported prefix-read diagnostic
showing little free-memory change is consistent with existing cache hits, but
this source review did not independently inspect that receipt or infer a cause.

Keep the implementation increment small:

1. The `File` constructor already opens a fresh `O_RDONLY|O_NOFOLLOW` regular
   descriptor; no earlier code enables no-cache or shares it during hashing.
   Immediately before the digest loop, require `fcntl(fd,F_NOCACHE,1)==0`.
   Failure must stop verification, rather than silently revert to cached reads.
2. Reuse one at-most-4MiB mutable buffer across the sequential `pread` loop.
   Existing `read(into:offset:)` already handles interrupted/short reads and exact
   bounds. Feed only the filled prefix to `SHA256.update(bufferPointer:)`, with
   exact final-block length and the same offset progression. A page-aligned
   buffer is optional for direct-IO efficiency; it is not needed to promise
   read correctness or caching semantics. Do not add a second file hash.
3. Preserve `checkUnchanged()` after the complete read. Attempt
   `fcntl(fd,F_NOCACHE,0)` on every success or thrown-error path. Restoration
   failure must prevent publication; when reading/identity also failed, retain
   that primary failure and identify the restoration error as cleanup. Avoid a
   `try?`/unchecked `defer` that silently leaves policy changed.
4. Return the digest only after restoration. Existing per-file hash checks,
   sorted aggregate construction, manifest/config pins and pinned descriptor
   reuse remain unchanged. Tensor payload reads therefore retain their current
   caching policy and ownership. No CLI flag, loader permit or result schema is
   needed. This scope assumes exclusive fresh `File` ownership, not a generic
   policy-restoration utility for arbitrary externally supplied descriptors.

Root can compile a Foundation/CryptoKit/Darwin fixture using invented temporary
files: empty, partial-block, exactly-one-block and multi-block contents produce
the expected raw SHA and existing manifest aggregate; corrupt/truncated files
still fail. A small injected fcntl/read seam can test enable refusal before any
read, restoration on read/fstat failure, restoration failure blocking success,
and both errors retained in order. Existing constructor fixtures should remain
unchanged as regression checks. Then repeat the guarded registered9B checksum
probe with the same complete hash/oracle gates and explicit OS observations.

Do not run another verified reread as a cache-reclamation step, use
`F_GLOBAL_NOCACHE`, or add global purge/VM cache manipulation. The reviewed
public per-descriptor API provides no reliable old-page reclamation guarantee.
Keep the post-hash actual-free admission and the established 6GiB loading floor:
this IO change reduces a known source of pressure; it does not create memory or
authorize a previously refused 27B load.
