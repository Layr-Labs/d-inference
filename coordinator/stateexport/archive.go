package stateexport

import (
	"archive/zip"
	"context"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
)

// ArchiveResult summarizes a completed archive build.
type ArchiveResult struct {
	// Files is the number of entries (regular files + db snapshots) written into
	// the zip. Directory entries are not counted.
	Files int
	// SnapshottedDBs is the number of *.db files that went through the
	// hot-copy+validate bolt snapshotter.
	SnapshottedDBs int
}

// Archiver builds a zip of the export root in two phases:
//
//	Phase A (Stage):  snapshot+validate every *.db under the root into a
//	                  controlled staging dir. Any failure here is fail-clean —
//	                  the caller has not written any response bytes yet.
//	Phase B (Write):  stream the zip from disk + the validated staging copies.
//
// Splitting the phases is what makes the HTTP handler able to return a real 500
// (nothing written) when a db cannot be snapshotted, instead of a structurally
// valid but silently-partial archive after a 200.
type Archiver struct {
	// Snapshotter produces a consistent copy of each *.db file. Injectable so
	// tests can exercise the walk/zip logic with a fake.
	Snapshotter Snapshotter
	// TmpDir is where db snapshots are staged. Empty => os.MkdirTemp default.
	TmpDir string
	// Logger receives WARN logs (empty archive, step-ca Badger db present). May
	// be nil.
	Logger *slog.Logger
}

// NewArchiver returns an Archiver using the production bolt snapshotter.
func NewArchiver() *Archiver {
	return &Archiver{Snapshotter: NewBoltSnapshotter()}
}

// StagedExport is the validated, pre-staged result of Phase A. It owns a
// temporary staging directory that the caller MUST release with Cleanup() once
// the archive has been streamed (or on any error).
type StagedExport struct {
	// root is the symlink-resolved export root that Phase B walks.
	root string
	// stagingDir is the 0700 temp dir holding validated db copies.
	stagingDir string
	// dbSnapshots maps the resolved absolute path of each live *.db to the path
	// of its validated staging copy.
	dbSnapshots map[string]string
	logger      *slog.Logger
}

// Cleanup removes the staging directory and all validated db copies. Safe to
// call multiple times and on a nil receiver.
func (s *StagedExport) Cleanup() {
	if s == nil || s.stagingDir == "" {
		return
	}
	_ = os.RemoveAll(s.stagingDir)
	s.stagingDir = ""
}

// hasExtension reports whether name has the given extension (case-insensitive).
func hasExtension(name, ext string) bool {
	return strings.EqualFold(filepath.Ext(name), ext)
}

// isLog reports whether the file should be excluded as a log file.
func isLog(name string) bool { return hasExtension(name, ".log") }

// isBoltDB reports whether the file is a BoltDB database (by extension).
func isBoltDB(name string) bool { return hasExtension(name, ".db") }

// Stage performs Phase A: it resolves the (possibly symlinked) root, snapshots
// and validates every *.db under it into a freshly-created 0700 staging dir, and
// returns a StagedExport. The caller MUST call Cleanup() on the returned value.
//
// Any failure here — bad root, a db that won't yield a consistent snapshot after
// retries, OR an empty/degenerate export (0 files, or a micromdm dir with 0 db
// snapshots) — returns an error with nothing else mutated, so the HTTP handler
// can still emit a clean 500 BEFORE any response byte is written. Catching the
// empty/0-db case here (rather than in Write) is what prevents a truncated but
// successful-looking 200 download. ctx cancellation aborts the walk.
func (a *Archiver) Stage(ctx context.Context, root string) (*StagedExport, error) {
	// Prod start.sh does `ln -sfn $PERSIST /data`, so the export root is itself a
	// symlink. filepath.WalkDir does NOT follow a symlinked root — it would walk
	// zero children and silently produce an EMPTY archive. Resolve the link first.
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, fmt.Errorf("resolve export root %q: %w", root, err)
	}

	info, err := os.Stat(resolved)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("export root %q does not exist", root)
		}
		return nil, fmt.Errorf("stat export root %q: %w", root, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("export root %q is not a directory", root)
	}

	snap := a.Snapshotter
	if snap == nil {
		snap = NewBoltSnapshotter()
	}

	// One controlled staging dir (0700) so validated copies never leak into
	// os.TempDir() and survive a crash. The caller's Cleanup() removes it.
	stagingDir, err := os.MkdirTemp(a.TmpDir, "stateexport-stage-")
	if err != nil {
		return nil, fmt.Errorf("create staging dir: %w", err)
	}
	if err := os.Chmod(stagingDir, 0o700); err != nil {
		_ = os.RemoveAll(stagingDir)
		return nil, fmt.Errorf("chmod staging dir: %w", err)
	}

	staged := &StagedExport{
		root:        resolved,
		stagingDir:  stagingDir,
		dbSnapshots: map[string]string{},
		logger:      a.Logger,
	}

	// Precondition tracking, computed during the same walk so the empty/0-db
	// guard fires in Phase A (before any response byte). fileCount counts every
	// entry that Phase B would WRITE — regular files AND *.db (dirs, symlinks, and
	// *.log are not written and not counted).
	fileCount := 0
	micromdmDir := ""    // resolved path of the micromdm dir, if present
	micromdmDBCount := 0 // *.db snapshots taken INSIDE micromdm/

	walkErr := filepath.WalkDir(resolved, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		// Skip symlinks under the root — only the root itself is intentionally a
		// link; interior links could escape the root or duplicate content.
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if d.IsDir() {
			if d.Name() == "micromdm" {
				micromdmDir = path
			}
			// step-ca's default standalone DB is a Badger DIRECTORY at
			// step-ca/db/, NOT a *.db file. We deliberately do NOT snapshot it:
			// step-ca writes are rare (cert issuance) and the CA private keys live
			// in secrets/+certs/ as copy-safe PEM, so a torn db/ index is
			// recoverable. Warn the operator so they can quiesce enrollments
			// during the one-time export.
			if d.Name() == "db" && filepath.Base(filepath.Dir(path)) == "step-ca" {
				if staged.logger != nil {
					staged.logger.Warn("state-export: step-ca Badger db present and is copied file-by-file (no snapshot); quiesce certificate enrollments during the export to avoid a torn index",
						"path", path)
				}
			}
			return nil
		}
		if isLog(d.Name()) {
			return nil // excluded from the archive; not a written file
		}
		if !isBoltDB(d.Name()) {
			fileCount++ // regular file streamed in Phase B
			return nil
		}

		tmpPath, serr := snap.Snapshot(ctx, path, stagingDir)
		if serr != nil {
			return fmt.Errorf("snapshot bolt db %q: %w", path, serr)
		}
		staged.dbSnapshots[path] = tmpPath
		fileCount++ // *.db is written in Phase B from its staging snapshot
		// Count *.db snapshots taken INSIDE the micromdm dir specifically. The
		// fail-loud guard below must require MicroMDM's OWN database — a stray db
		// elsewhere under the root must not mask a missing MicroMDM db and let us
		// ship an archive without it.
		if micromdmDir != "" && strings.HasPrefix(path, micromdmDir+string(filepath.Separator)) {
			micromdmDBCount++
		}
		return nil
	})
	if walkErr != nil {
		staged.Cleanup()
		return nil, walkErr
	}

	// Fail loud on an empty/degenerate export BEFORE returning — this is a
	// one-way migration tool, so a 0-file or 0-db export is a disaster, and the
	// handler maps a Stage error to a clean pre-stream 500 (zero bytes sent).
	if fileCount == 0 {
		if staged.logger != nil {
			staged.logger.Warn("state-export: archive would capture ZERO files — refusing to stage empty export",
				"root", resolved)
		}
		staged.Cleanup()
		return nil, fmt.Errorf("export captured 0 files under %q (empty or unreadable root)", resolved)
	}
	if micromdmDir != "" && micromdmDBCount == 0 {
		if staged.logger != nil {
			staged.logger.Warn("state-export: micromdm dir present but its BoltDB was not snapshotted — refusing to stage",
				"root", resolved, "micromdm_dir", micromdmDir)
		}
		staged.Cleanup()
		return nil, fmt.Errorf("micromdm dir present under %q but its BoltDB (*.db inside micromdm/) was not snapshotted", resolved)
	}

	return staged, nil
}

// Write performs Phase B: it streams the zip for an already-staged export to w.
// Relative paths under the resolved root and file modes are preserved. *.log
// files are excluded. *.db files are replaced with their validated staging
// snapshot (taken in Phase A).
//
// The empty/0-db fail-loud guard lives in Stage (Phase A), so by the time Write
// runs the export is known non-degenerate; Write is a pure streamer that returns
// the counts. ctx cancellation aborts the walk.
//
// On a mid-stream error the zip writer is NOT Close()d, so the client receives a
// truncated, clearly-broken download instead of a structurally valid partial
// archive.
func (a *Archiver) Write(ctx context.Context, staged *StagedExport, w io.Writer) (ArchiveResult, error) {
	var res ArchiveResult
	if staged == nil {
		return res, fmt.Errorf("nil staged export")
	}

	zw := zip.NewWriter(w)
	walkErr := filepath.WalkDir(staged.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}

		rel, relErr := filepath.Rel(staged.root, path)
		if relErr != nil {
			return relErr
		}
		if rel == "." {
			return nil
		}

		// Skip symlinks entirely — following links could escape the root or
		// duplicate content.
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}

		if d.IsDir() {
			return addDirEntry(zw, rel, d)
		}

		if isLog(d.Name()) {
			return nil // excluded
		}

		if isBoltDB(d.Name()) {
			snapPath, ok := staged.dbSnapshots[path]
			if !ok {
				return fmt.Errorf("missing staged snapshot for %q", rel)
			}
			if err := addStagedDB(zw, snapPath, rel, d); err != nil {
				return err
			}
			res.SnapshottedDBs++
			res.Files++
			return nil
		}

		if err := addRegularFile(zw, path, rel, d); err != nil {
			return err
		}
		res.Files++
		return nil
	})
	if walkErr != nil {
		// Do NOT Close() the zip writer: leaving the central directory unwritten
		// yields a truncated (clearly-broken) download rather than a
		// structurally-valid partial zip.
		return res, walkErr
	}

	if err := zw.Close(); err != nil {
		return res, fmt.Errorf("finalize zip: %w", err)
	}
	return res, nil
}

// zipName converts an OS-specific relative path to a forward-slash zip name.
func zipName(rel string) string {
	return filepath.ToSlash(rel)
}

// addDirEntry writes an explicit directory entry so empty dirs are preserved.
func addDirEntry(zw *zip.Writer, rel string, d fs.DirEntry) error {
	info, err := d.Info()
	if err != nil {
		return err
	}
	hdr, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	hdr.Name = zipName(rel) + "/"
	hdr.Method = zip.Store
	_, err = zw.CreateHeader(hdr)
	return err
}

// addRegularFile streams a regular file into the zip, preserving its mode.
func addRegularFile(zw *zip.Writer, path, rel string, d fs.DirEntry) error {
	info, err := d.Info()
	if err != nil {
		return err
	}
	hdr, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	hdr.Name = zipName(rel)
	hdr.Method = zip.Deflate

	wtr, err := zw.CreateHeader(hdr)
	if err != nil {
		return err
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.Copy(wtr, f); err != nil {
		return fmt.Errorf("copy %q into archive: %w", rel, err)
	}
	return nil
}

// addStagedDB streams the pre-validated staging copy of a bolt db into the zip
// under the original relative path, preserving the live file's mode and name.
func addStagedDB(zw *zip.Writer, snapPath, rel string, d fs.DirEntry) error {
	// Preserve the live db's mode/name in the header, but stream the validated
	// staging copy.
	info, err := d.Info()
	if err != nil {
		return err
	}
	hdr, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	hdr.Name = zipName(rel)
	hdr.Method = zip.Deflate

	wtr, err := zw.CreateHeader(hdr)
	if err != nil {
		return err
	}
	snapFile, err := os.Open(snapPath)
	if err != nil {
		return err
	}
	defer snapFile.Close()
	if _, err := io.Copy(wtr, snapFile); err != nil {
		return fmt.Errorf("copy bolt snapshot %q into archive: %w", rel, err)
	}
	return nil
}
