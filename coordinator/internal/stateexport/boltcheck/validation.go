package boltcheck

import (
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
func Validate(path string, openTimeout time.Duration) (retErr error) {
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
