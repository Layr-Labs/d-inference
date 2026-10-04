// Package stateexport produces a consistent, optionally-encrypted archive of the
// coordinator's TEE-sealed on-disk state (MicroMDM and its neighbours) under /data so it
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
	"fmt"
	"io"
	"os"
	"time"

	boltcheck "github.com/eigeninference/d-inference/coordinator/internal/stateexport/boltcheck"
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

		if err := boltcheck.Validate(tmpPath, snapshotOpenTimeout); err != nil {
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
