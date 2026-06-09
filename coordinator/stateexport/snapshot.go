// Package stateexport produces a consistent, optionally-encrypted archive of the
// coordinator's TEE-sealed on-disk state (step-ca + MicroMDM) under /data so it
// can be migrated off EigenCloud onto a GCP Confidential VM (DAR-70).
//
// The crux is BoltDB consistency: MicroMDM runs as a sibling process that holds
// an exclusive bbolt file lock for its lifetime, so the live db cannot be opened
// in-process and a naive byte copy can capture a torn write. snapshot.go
// implements hot-copy + validate + retry to obtain a clean snapshot.
//
// Torn-copy safety: a torn hot-copy can have a meta page with a VALID checksum
// whose pgid points past the end of the file (the write that grew the file had
// not been flushed when we copied). bbolt indexes the mmap with no bounds check,
// so walking such a copy can PANIC rather than return an error. Worse, tx.Check()
// runs its work in an internal goroutine, so a panic there is unrecoverable by
// the caller and crashes the process. We therefore (a) NEVER use tx.Check() in
// the production validation path, and (b) wrap copy-open-validate in a recover so
// ANY panic becomes a retry-able error.
package stateexport

import (
	"context"
	"encoding/binary"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"time"

	bolt "go.etcd.io/bbolt"
)

// bbolt on-disk constants (mirrored from go.etcd.io/bbolt/internal/common; they
// are part of the stable v2 file format). We read the meta pages by hand so we
// can reject a torn copy WITHOUT mmap-walking it — an mmap walk of a torn file
// can SIGSEGV (an out-of-bounds mmap read), which is a fatal runtime fault that
// recover() cannot catch.
const (
	boltMagic   uint32 = 0xED0CDAED
	boltVersion uint32 = 2
	// Page header is {id u64, flags u16, count u16, overflow u32} = 16 bytes.
	boltPageHeaderSize = 16
	// Offsets WITHIN the Meta struct (which begins right after the page header):
	//   magic u32 | version u32 | pageSize u32 | flags u32 |
	//   root{rootPgid u64, seq u64} | freelist u64 | pgid u64 | txid u64 | checksum u64
	metaOffMagic    = 0
	metaOffVersion  = 4
	metaOffPageSize = 8
	metaOffPgid     = 40 // high-water mark: total pages the db claims to use
	metaOffTxid     = 48
	metaOffChecksum = 56 // FNV-1a is computed over meta bytes [0:56)
	metaStructLen   = 64
)

// Snapshotter produces a consistent copy of a BoltDB file. It is injectable so
// archive-building tests can exercise the walk/zip logic without a live db.
type Snapshotter interface {
	// Snapshot writes a consistent copy of the bbolt database at srcPath into a
	// freshly-created temp file and returns that file's path. The caller owns the
	// returned file and must remove it when done. tmpDir, when non-empty, is the
	// directory the temp file is created in (defaults to os.TempDir()). ctx
	// cancellation aborts the retry loop between attempts.
	Snapshot(ctx context.Context, srcPath, tmpDir string) (string, error)
}

// Hot-copy + validate + retry tuning. MicroMDM write txns are sub-millisecond,
// so a clean snapshot is obtained within a few attempts.
const (
	// maxSnapshotAttempts is how many times to retry the copy+validate cycle.
	maxSnapshotAttempts = 5
	// snapshotBackoff is the pause between attempts.
	snapshotBackoff = 25 * time.Millisecond
	// snapshotOpenTimeout bounds bbolt.Open on the copy (it should never block —
	// the copy is unlocked — but a short timeout fails fast on a bad file).
	snapshotOpenTimeout = 2 * time.Second
)

// BoltSnapshotter is the production Snapshotter: hot-copy the live db bytes to a
// temp file, open the COPY read-only (no lock contention), validate integrity,
// and retry on failure. It never opens or modifies the live db read-write.
type BoltSnapshotter struct{}

// NewBoltSnapshotter returns a BoltSnapshotter.
func NewBoltSnapshotter() *BoltSnapshotter {
	return &BoltSnapshotter{}
}

// Snapshot implements Snapshotter.
func (b *BoltSnapshotter) Snapshot(ctx context.Context, srcPath, tmpDir string) (string, error) {
	var lastErr error
	for attempt := 1; attempt <= maxSnapshotAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}

		tmpPath, err := copyFileToTemp(srcPath, tmpDir)
		if err != nil {
			// A copy error is unlikely to self-heal across retries (bad path,
			// perms) — fail fast.
			return "", fmt.Errorf("hot-copy bolt db %q: %w", srcPath, err)
		}

		if err := validateBolt(tmpPath, snapshotOpenTimeout); err != nil {
			lastErr = err
			_ = os.Remove(tmpPath)
			if attempt < maxSnapshotAttempts {
				// Cancellable wait so a client disconnect aborts the retry loop
				// instead of sleeping out the full backoff.
				select {
				case <-ctx.Done():
					return "", ctx.Err()
				case <-time.After(snapshotBackoff):
				}
			}
			continue
		}

		// Validated copy — caller owns it.
		return tmpPath, nil
	}

	return "", fmt.Errorf("bolt db %q did not yield a consistent snapshot after %d attempts: %w",
		srcPath, maxSnapshotAttempts, lastErr)
}

// copyFileToTemp copies the bytes of srcPath into a new temp file (preserving the
// source's base name pattern) and returns the temp path. The destination is a
// brand-new file, so the writer never touches the live db's bytes.
func copyFileToTemp(srcPath, tmpDir string) (string, error) {
	src, err := os.Open(srcPath)
	if err != nil {
		return "", err
	}
	defer src.Close()

	if tmpDir == "" {
		tmpDir = os.TempDir()
	}
	dst, err := os.CreateTemp(tmpDir, "stateexport-bolt-*.db")
	if err != nil {
		return "", err
	}
	tmpPath := dst.Name()

	if _, err := io.Copy(dst, src); err != nil {
		dst.Close()
		_ = os.Remove(tmpPath)
		return "", err
	}
	if err := dst.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return "", err
	}
	return tmpPath, nil
}

// validateBolt confirms the (already-copied) db is a complete, non-torn snapshot.
//
// Two layers, both crash-safe:
//
//  1. A pure byte-level meta check (mmap-free): read both meta pages, validate
//     magic/version/FNV checksum, pick the active meta (highest valid txid), and
//     confirm its high-water-mark pgid fits inside the file. THIS is the layer
//     that catches the dangerous torn copy — a meta whose pgid points past EOF —
//     because the subsequent mmap walk of such a file SIGSEGVs (a fatal runtime
//     fault, NOT a Go panic; recover() cannot catch it).
//
//  2. A recover-wrapped read-only bucket walk. With layer 1 guaranteeing the
//     high-water mark fits, this is safe; the recover is belt-and-suspenders for
//     any other internal inconsistency that surfaces as a panic. We deliberately
//     do NOT use tx.Check(): it runs in an internal goroutine, so a panic there
//     would crash the process regardless of any recover here.
func validateBolt(path string, openTimeout time.Duration) (retErr error) {
	defer func() {
		if rec := recover(); rec != nil {
			// Preserve the underlying error type (and chain) when the recovered
			// value is itself an error; otherwise stringify it.
			if e, ok := rec.(error); ok {
				retErr = fmt.Errorf("bolt validation panicked (torn/corrupt copy): %w", e)
			} else {
				retErr = fmt.Errorf("bolt validation panicked (torn/corrupt copy): %v", rec)
			}
		}
	}()

	// Layer 1: byte-level meta validation. Rejects torn copies before any mmap.
	if err := validateBoltMeta(path); err != nil {
		return err
	}

	// Layer 2: recover-wrapped structural walk on the now-known-bounded copy.
	db, err := bolt.Open(path, 0o400, &bolt.Options{
		ReadOnly: true,
		Timeout:  openTimeout,
	})
	if err != nil {
		return fmt.Errorf("open copy read-only: %w", err)
	}
	defer db.Close()

	if err := db.View(walkAllBuckets); err != nil {
		return fmt.Errorf("walk buckets: %w", err)
	}
	return nil
}

// validateBoltMeta reads the two meta pages straight from the file bytes (no
// mmap, fully bounds-checked) and confirms the snapshot is complete:
//   - page size is plausible (power of two, >= 512);
//   - file size is a whole number of pages and >= 2 pages;
//   - at least one meta page is valid (correct magic/version/FNV checksum);
//   - the active meta's high-water-mark pgid fits inside the file.
//
// The last condition is the torn-copy signature: a hot-copy taken mid-grow can
// have a valid-checksum meta claiming N pages while the file holds fewer — the
// write that extended the file had not reached disk when we copied it.
func validateBoltMeta(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return err
	}
	size := info.Size()

	// Page size lives at file offset boltPageHeaderSize+metaOffPageSize in meta
	// page 0. Read enough of page 0 to cover the whole meta struct.
	page0 := make([]byte, boltPageHeaderSize+metaStructLen)
	if _, err := io.ReadFull(f, page0); err != nil {
		return fmt.Errorf("read bolt meta page 0: %w", err)
	}
	pageSize := int64(binary.LittleEndian.Uint32(page0[boltPageHeaderSize+metaOffPageSize:]))
	if pageSize < 512 || pageSize&(pageSize-1) != 0 {
		return fmt.Errorf("implausible bolt page size %d (torn/corrupt copy)", pageSize)
	}
	if size < 2*pageSize {
		return fmt.Errorf("bolt copy too small: %d bytes < 2 pages (%d) — torn copy", size, 2*pageSize)
	}
	if size%pageSize != 0 {
		return fmt.Errorf("bolt copy size %d is not a multiple of page size %d — torn copy", size, pageSize)
	}

	// Read meta page 1 (the second copy of the meta).
	page1 := make([]byte, boltPageHeaderSize+metaStructLen)
	if _, err := f.ReadAt(page1, pageSize); err != nil {
		return fmt.Errorf("read bolt meta page 1: %w", err)
	}

	totalPages := size / pageSize
	pgid0, ok0 := parseBoltMeta(page0)
	pgid1, ok1 := parseBoltMeta(page1)
	txid0 := binary.LittleEndian.Uint64(page0[boltPageHeaderSize+metaOffTxid:])
	txid1 := binary.LittleEndian.Uint64(page1[boltPageHeaderSize+metaOffTxid:])

	// Pick the active meta: the valid one with the highest txid (bbolt's rule).
	var activePgid uint64
	switch {
	case ok0 && ok1:
		if txid0 >= txid1 {
			activePgid = pgid0
		} else {
			activePgid = pgid1
		}
	case ok0:
		activePgid = pgid0
	case ok1:
		activePgid = pgid1
	default:
		return fmt.Errorf("no valid bolt meta page (both failed magic/version/checksum) — torn/corrupt copy")
	}

	// High-water mark must fit inside the file. If the meta claims more pages
	// than the file holds, the copy is torn — reject WITHOUT walking the mmap.
	// Compare in uint64 space: a pgid with the high bit set would become a
	// negative int64 and silently pass the bounds check (the exact torn-copy
	// signature this guard exists to catch). totalPages = size/pageSize ≥ 0.
	if totalPages < 0 || activePgid > uint64(totalPages) {
		return fmt.Errorf("bolt high-water mark pgid %d exceeds file pages %d — torn copy", activePgid, totalPages)
	}
	return nil
}

// parseBoltMeta validates a meta page's magic, version, and FNV-1a checksum, and
// returns its high-water-mark pgid. ok is false if the meta is not valid.
func parseBoltMeta(page []byte) (pgid uint64, ok bool) {
	meta := page[boltPageHeaderSize:]
	if len(meta) < metaStructLen {
		return 0, false
	}
	if binary.LittleEndian.Uint32(meta[metaOffMagic:]) != boltMagic {
		return 0, false
	}
	if binary.LittleEndian.Uint32(meta[metaOffVersion:]) != boltVersion {
		return 0, false
	}
	// FNV-1a 64-bit over meta bytes [0:checksumOffset).
	h := fnv.New64a()
	_, _ = h.Write(meta[:metaOffChecksum])
	want := binary.LittleEndian.Uint64(meta[metaOffChecksum:])
	if h.Sum64() != want {
		return 0, false
	}
	return binary.LittleEndian.Uint64(meta[metaOffPgid:]), true
}

// walkAllBuckets recursively iterates every bucket and key in the transaction.
func walkAllBuckets(tx *bolt.Tx) error {
	return tx.ForEach(func(name []byte, b *bolt.Bucket) error {
		return walkBucket(b)
	})
}

// walkBucket recursively touches every key/value and descends into nested
// buckets. Bucket.ForEach yields v==nil for a nested bucket; we re-fetch the
// sub-bucket via Bucket(name) and recurse so deep structures are validated too.
func walkBucket(b *bolt.Bucket) error {
	return b.ForEach(func(k, v []byte) error {
		if v == nil {
			if sub := b.Bucket(k); sub != nil {
				return walkBucket(sub)
			}
		}
		return nil
	})
}
