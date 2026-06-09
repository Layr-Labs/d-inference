package stateexport

import (
	"archive/zip"
	"fmt"
	"io"
	"io/fs"
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

// Logger is the minimal logging surface the archiver needs. It matches the
// shape of *slog.Logger's WARN method so the handler can pass its logger
// directly without coupling this package to a concrete logger.
type Logger interface {
	Warn(msg string, args ...any)
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
	Logger Logger
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
	logger      Logger
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

// isLog reports whether the file should be excluded as a log file.
func isLog(name string) bool {
	return strings.EqualFold(filepath.Ext(name), ".log")
}

// isBoltDB reports whether the file is a BoltDB database (by extension).
func isBoltDB(name string) bool {
	return strings.EqualFold(filepath.Ext(name), ".db")
}

// Stage performs Phase A: it resolves the (possibly symlinked) root, snapshots
// and validates every *.db under it into a freshly-created 0700 staging dir, and
// returns a StagedExport. The caller MUST call Cleanup() on the returned value.
//
// Any failure here — bad root, or a db that won't yield a consistent snapshot
// after retries — returns an error with nothing else mutated, so the HTTP
// handler can still emit a clean 500.
func (a *Archiver) Stage(root string) (*StagedExport, error) {
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

	walkErr := filepath.WalkDir(resolved, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		// Skip symlinks under the root — only the root itself is intentionally a
		// link; interior links could escape the root or duplicate content.
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if d.IsDir() {
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
		if isLog(d.Name()) || !isBoltDB(d.Name()) {
			return nil // *.db handled below; everything else is streamed in Phase B
		}

		tmpPath, serr := snap.Snapshot(path, stagingDir)
		if serr != nil {
			return fmt.Errorf("snapshot bolt db %q: %w", path, serr)
		}
		staged.dbSnapshots[path] = tmpPath
		return nil
	})
	if walkErr != nil {
		staged.Cleanup()
		return nil, walkErr
	}

	return staged, nil
}

// Write performs Phase B: it streams the zip for an already-staged export to w.
// Relative paths under the resolved root and file modes are preserved. *.log
// files are excluded. *.db files are replaced with their validated staging
// snapshot (taken in Phase A).
//
// Fail-loud: this is a one-way migration tool, so an empty export is a disaster.
// If the archive captures 0 files, or 0 db snapshots while a micromdm dir
// exists, Write returns an error (and WARN-logs) rather than finalizing a clean
// but empty zip.
//
// On a mid-stream error the zip writer is NOT Close()d, so the client receives a
// truncated, clearly-broken download instead of a structurally valid partial
// archive.
func (a *Archiver) Write(staged *StagedExport, w io.Writer) (ArchiveResult, error) {
	var res ArchiveResult
	if staged == nil {
		return res, fmt.Errorf("nil staged export")
	}

	micromdmDirSeen := false

	zw := zip.NewWriter(w)
	walkErr := filepath.WalkDir(staged.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
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
			if d.Name() == "micromdm" {
				micromdmDirSeen = true
			}
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

	// Fail loud on an empty/degenerate export BEFORE finalizing the zip.
	if res.Files == 0 {
		if a.Logger != nil {
			a.Logger.Warn("state-export: archive captured ZERO files — refusing to finalize empty export",
				"root", staged.root)
		}
		return res, fmt.Errorf("export captured 0 files under %q (empty or unreadable root)", staged.root)
	}
	if micromdmDirSeen && res.SnapshottedDBs == 0 {
		if a.Logger != nil {
			a.Logger.Warn("state-export: micromdm dir present but ZERO db snapshots captured — refusing to finalize",
				"root", staged.root)
		}
		return res, fmt.Errorf("micromdm dir present under %q but 0 db snapshots captured", staged.root)
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
