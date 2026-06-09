package stateexport

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/binary"
	"hash/fnv"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"filippo.io/age"
	bolt "go.etcd.io/bbolt"
)

// makeBolt creates a real bbolt db at path with a couple of buckets + keys.
func makeBolt(t *testing.T, path string) {
	t.Helper()
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open bolt: %v", err)
	}
	defer db.Close()
	if err := db.Update(func(tx *bolt.Tx) error {
		dev, err := tx.CreateBucketIfNotExists([]byte("Devices"))
		if err != nil {
			return err
		}
		if err := dev.Put([]byte("serial-1"), []byte("payload-1")); err != nil {
			return err
		}
		if err := dev.Put([]byte("serial-2"), []byte("payload-2")); err != nil {
			return err
		}
		cmd, err := tx.CreateBucketIfNotExists([]byte("Commands"))
		if err != nil {
			return err
		}
		return cmd.Put([]byte("cmd-1"), []byte("InstallProfile"))
	}); err != nil {
		t.Fatalf("seed bolt: %v", err)
	}
}

// archiveRoot runs the two-phase Archiver (Stage then Write) end-to-end against
// root and returns the zip bytes + result. It always cleans up staging.
func archiveRoot(t *testing.T, a *Archiver, root string, w io.Writer) (ArchiveResult, error) {
	t.Helper()
	staged, err := a.Stage(context.Background(), root)
	if err != nil {
		return ArchiveResult{}, err
	}
	defer staged.Cleanup()
	return a.Write(context.Background(), staged, w)
}

// unzipToMap reads a zip from r and returns name -> contents (files only).
func unzipToMap(t *testing.T, r io.ReaderAt, size int64) map[string][]byte {
	t.Helper()
	zr, err := zip.NewReader(r, size)
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	out := map[string][]byte{}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			t.Fatalf("open zip entry %q: %v", f.Name, err)
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatalf("read zip entry %q: %v", f.Name, err)
		}
		out[f.Name] = b
	}
	return out
}

// buildExportRoot lays down a representative /data tree and returns its path.
func buildExportRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	mustWrite(t, filepath.Join(root, "step-ca", "config", "ca.json"), `{"authority":{}}`)
	mustWrite(t, filepath.Join(root, "step-ca", "secrets", "password"), "eigeninference-step-ca")
	mustWrite(t, filepath.Join(root, "step-ca", "certs", "root_ca.crt"), "ROOT-CERT")
	mustWrite(t, filepath.Join(root, "step-ca", "certs", "intermediate_ca.crt"), "INT-CERT")
	mustWrite(t, filepath.Join(root, "step-ca", "certs", "intermediate_ca_key"), "INT-KEY")

	mustWrite(t, filepath.Join(root, "micromdm", "push.crt"), "PUSH-CERT")
	mustWrite(t, filepath.Join(root, "micromdm", "push.key"), "PUSH-KEY")
	mustWrite(t, filepath.Join(root, "micromdm", "config"), "CONFIG")
	mustWrite(t, filepath.Join(root, "micromdm", ".push_imported"), "") // sentinel
	makeBolt(t, filepath.Join(root, "micromdm", "micromdm.db"))

	// Log files that MUST be excluded.
	mustWrite(t, filepath.Join(root, "step-ca.log"), "step log")
	mustWrite(t, filepath.Join(root, "micromdm", "micromdm.log"), "mdm log")

	return root
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %q: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %q: %v", path, err)
	}
}

// TestArchiveWritesExpectedTree verifies the walk/zip logic: correct paths,
// *.log excluded, .push_imported sentinel included, bolt db snapshotted.
func TestArchiveWritesExpectedTree(t *testing.T) {
	root := buildExportRoot(t)

	var buf bytes.Buffer
	res, err := archiveRoot(t, NewArchiver(), root, &buf)
	if err != nil {
		t.Fatalf("archive: %v", err)
	}
	if res.SnapshottedDBs != 1 {
		t.Fatalf("expected 1 snapshotted db, got %d", res.SnapshottedDBs)
	}

	files := unzipToMap(t, bytes.NewReader(buf.Bytes()), int64(buf.Len()))

	wantPresent := []string{
		"step-ca/config/ca.json",
		"step-ca/secrets/password",
		"step-ca/certs/root_ca.crt",
		"step-ca/certs/intermediate_ca.crt",
		"step-ca/certs/intermediate_ca_key",
		"micromdm/push.crt",
		"micromdm/push.key",
		"micromdm/config",
		"micromdm/.push_imported",
		"micromdm/micromdm.db",
	}
	for _, name := range wantPresent {
		if _, ok := files[name]; !ok {
			t.Errorf("expected %q in archive, missing", name)
		}
	}

	wantAbsent := []string{"step-ca.log", "micromdm/micromdm.log"}
	for _, name := range wantAbsent {
		if _, ok := files[name]; ok {
			t.Errorf("expected %q to be EXCLUDED, but present", name)
		}
	}

	// The snapshotted db inside the zip must open ReadOnly with intact data.
	dbBytes, ok := files["micromdm/micromdm.db"]
	if !ok {
		t.Fatal("micromdm.db missing from archive")
	}
	assertBoltIntact(t, dbBytes)
}

// assertBoltIntact writes dbBytes to a temp file, validates it with the
// production recover-wrapped validator (NOT tx.Check(), which panics in a
// goroutine on a torn copy), and verifies the seeded buckets/keys are present.
func assertBoltIntact(t *testing.T, dbBytes []byte) {
	t.Helper()
	tmp := filepath.Join(t.TempDir(), "extracted.db")
	if err := os.WriteFile(tmp, dbBytes, 0o600); err != nil {
		t.Fatalf("write extracted db: %v", err)
	}
	if err := validateBolt(tmp, 2*time.Second); err != nil {
		t.Fatalf("extracted db failed validation: %v", err)
	}

	db, err := bolt.Open(tmp, 0o400, &bolt.Options{ReadOnly: true, Timeout: 2 * time.Second})
	if err != nil {
		t.Fatalf("open extracted db ReadOnly: %v", err)
	}
	defer db.Close()
	if err := db.View(func(tx *bolt.Tx) error {
		dev := tx.Bucket([]byte("Devices"))
		if dev == nil {
			t.Fatal("Devices bucket missing in extracted db")
		}
		if got := dev.Get([]byte("serial-1")); !bytes.Equal(got, []byte("payload-1")) {
			t.Fatalf("serial-1 = %q, want payload-1", got)
		}
		if tx.Bucket([]byte("Commands")) == nil {
			t.Fatal("Commands bucket missing in extracted db")
		}
		return nil
	}); err != nil {
		t.Fatalf("verify buckets: %v", err)
	}
}

// TestArchiveMissingRoot returns a clear error when the root doesn't exist.
func TestArchiveMissingRoot(t *testing.T) {
	_, err := archiveRoot(t, NewArchiver(), filepath.Join(t.TempDir(), "nope"), io.Discard)
	if err == nil {
		t.Fatal("expected error for missing root")
	}
}

// TestArchiveEmptyRootErrors: a childless root is a degenerate (disastrous)
// export — Stage succeeds but Write must fail loud rather than finalize an empty
// zip.
func TestArchiveEmptyRootErrors(t *testing.T) {
	root := t.TempDir() // no children
	_, err := archiveRoot(t, NewArchiver(), root, io.Discard)
	if err == nil {
		t.Fatal("expected error for empty root, got nil")
	}
}

// TestArchiveMicromdmDirWithoutItsDB_DAR70 is the regression for the Codex PR
// finding: the fail-loud "micromdm present but no DB" guard must scope to a *.db
// INSIDE the micromdm dir, not the global snapshot count. A stray db elsewhere
// under the root (e.g. step-ca/) must not mask a missing MicroMDM database and
// let Stage succeed — that would ship a 200 archive without the MDM device DB.
func TestArchiveMicromdmDirWithoutItsDB_DAR70(t *testing.T) {
	root := t.TempDir()
	// micromdm dir exists but has NO *.db (only a regular file).
	mustWrite(t, filepath.Join(root, "micromdm", "config"), "CONFIG")
	// A stray bolt db elsewhere that WILL be snapshotted (global db count > 0).
	// mustWrite first so step-ca/ exists before bolt.Open (makeBolt doesn't mkdir).
	mustWrite(t, filepath.Join(root, "step-ca", "ca.json"), "{}")
	makeBolt(t, filepath.Join(root, "step-ca", "stray.db"))

	_, err := archiveRoot(t, NewArchiver(), root, io.Discard)
	if err == nil {
		t.Fatal("expected error: micromdm dir present but its BoltDB missing, masked by a stray db elsewhere")
	}
}

// TestArchiveSymlinkedRoot: prod start.sh symlinks /data -> persistent storage.
// WalkDir on a symlinked root would walk zero children; the archiver must
// EvalSymlinks first so the archive still captures children.
func TestArchiveSymlinkedRoot(t *testing.T) {
	real := buildExportRoot(t)
	link := filepath.Join(t.TempDir(), "data-link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	var buf bytes.Buffer
	res, err := archiveRoot(t, NewArchiver(), link, &buf)
	if err != nil {
		t.Fatalf("archive via symlinked root: %v", err)
	}
	if res.Files == 0 {
		t.Fatal("symlinked root produced an EMPTY archive (EvalSymlinks not applied)")
	}
	files := unzipToMap(t, bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if _, ok := files["micromdm/micromdm.db"]; !ok {
		t.Fatal("micromdm.db missing from symlinked-root archive")
	}
}

// TestArchiveMultipleDBs: every *.db under the root must be snapshotted.
func TestArchiveMultipleDBs(t *testing.T) {
	root := buildExportRoot(t)
	makeBolt(t, filepath.Join(root, "step-ca", "extra.db"))
	makeBolt(t, filepath.Join(root, "another.db"))

	var buf bytes.Buffer
	res, err := archiveRoot(t, NewArchiver(), root, &buf)
	if err != nil {
		t.Fatalf("archive: %v", err)
	}
	if res.SnapshottedDBs < 2 {
		t.Fatalf("expected >1 snapshotted db, got %d", res.SnapshottedDBs)
	}
	files := unzipToMap(t, bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	for _, name := range []string{"micromdm/micromdm.db", "step-ca/extra.db", "another.db"} {
		if _, ok := files[name]; !ok {
			t.Errorf("expected %q in archive, missing", name)
		}
	}
}

// TestEncryptRoundTrip encrypts a payload to a generated identity and decrypts.
func TestEncryptRoundTrip(t *testing.T) {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatalf("gen identity: %v", err)
	}

	var enc bytes.Buffer
	w, err := EncryptWriter(&enc, id.Recipient().String())
	if err != nil {
		t.Fatalf("encrypt writer: %v", err)
	}
	plaintext := []byte("darkbloom-state-bytes")
	if _, err := w.Write(plaintext); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close age writer: %v", err)
	}

	dr, err := age.Decrypt(bytes.NewReader(enc.Bytes()), id)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	got, err := io.ReadAll(dr)
	if err != nil {
		t.Fatalf("read decrypted: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Fatalf("decrypted = %q, want %q", got, plaintext)
	}
}

func TestValidateRecipient(t *testing.T) {
	id, _ := age.GenerateX25519Identity()
	if err := ValidateRecipient(id.Recipient().String()); err != nil {
		t.Fatalf("valid recipient rejected: %v", err)
	}
	if err := ValidateRecipient(""); err == nil {
		t.Fatal("empty recipient should error")
	}
	if err := ValidateRecipient("not-an-age-key"); err == nil {
		t.Fatal("garbage recipient should error")
	}
}

// TestSnapshotConsistencyUnderConcurrentWrites is the crux check for DAR-70: a
// goroutine hammers the LIVE source db with continuous Update writes while the
// snapshotter hot-copies it. The resulting snapshot must validate (via the
// recover-wrapped production validator) — i.e. never capture a torn write.
func TestSnapshotConsistencyUnderConcurrentWrites_DAR70(t *testing.T) {
	root := t.TempDir()
	dbPath := filepath.Join(root, "micromdm.db")
	makeBolt(t, dbPath)

	// Open the live db RW and keep it open for the duration (mirrors MicroMDM
	// holding the exclusive lock while we hot-copy the file bytes).
	live, err := bolt.Open(dbPath, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open live db: %v", err)
	}
	defer live.Close()

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		i := 0
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			_ = live.Update(func(tx *bolt.Tx) error {
				b, err := tx.CreateBucketIfNotExists([]byte("Churn"))
				if err != nil {
					return err
				}
				i++
				return b.Put([]byte("k"), []byte(time.Now().String()))
			})
		}
	}()

	snap := NewBoltSnapshotter()
	// Take several snapshots while writes are in-flight; each must be consistent.
	for n := 0; n < 8; n++ {
		tmp, err := snap.Snapshot(context.Background(), dbPath, root)
		if err != nil {
			cancel()
			wg.Wait()
			t.Fatalf("snapshot %d failed: %v", n, err)
		}
		verifySnapshotChecks(t, tmp)
		os.Remove(tmp)
	}

	cancel()
	wg.Wait()
}

// verifySnapshotChecks validates a snapshot with the production recover-wrapped
// validator. We deliberately do NOT use tx.Check(): on a genuinely torn copy
// Check() runs in an internal goroutine and a panic there would crash the whole
// `go test` binary rather than fail this test.
func verifySnapshotChecks(t *testing.T, path string) {
	t.Helper()
	if err := validateBolt(path, 2*time.Second); err != nil {
		t.Fatalf("snapshot failed validation: %v", err)
	}
}

// TestValidateBoltTornCopyFailsSafe is the regression for the CRITICAL finding:
// a hand-corrupted db file (valid header byte count but zeroed/truncated
// interior) must make validateBolt return an error WITHOUT panicking — never
// crash the process, never report a torn copy as clean.
func TestValidateBoltTornCopyFailsSafe(t *testing.T) {
	root := t.TempDir()
	good := filepath.Join(root, "good.db")
	makeBolt(t, good)
	// Grow the db so it has interior pages worth corrupting.
	live, err := bolt.Open(good, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := live.Update(func(tx *bolt.Tx) error {
		b, _ := tx.CreateBucketIfNotExists([]byte("Big"))
		for i := 0; i < 500; i++ {
			if err := b.Put([]byte{byte(i), byte(i >> 8)}, bytes.Repeat([]byte("x"), 256)); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("grow: %v", err)
	}
	live.Close()

	raw, err := os.ReadFile(good)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	cases := map[string][]byte{
		// Truncated mid-file: keep the two meta pages + a bit, drop the rest so
		// pgid in the meta points past EOF.
		"truncated": raw[:len(raw)/2],
		// Size not a multiple of the page size: append a stray byte.
		"misaligned": append(append([]byte{}, raw...), 0x00),
		// Interior pages zeroed: meta pages intact (so checksum may pass) but the
		// referenced data/branch pages are garbage.
		"zeroed-interior": zeroInterior(raw),
	}

	for name, corrupt := range cases {
		t.Run(name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "torn.db")
			if err := os.WriteFile(p, corrupt, 0o600); err != nil {
				t.Fatalf("write torn: %v", err)
			}
			// MUST NOT panic; MUST return an error. The recover in validateBolt
			// turns any internal bbolt panic into this error.
			err := validateBolt(p, time.Second)
			if err == nil {
				t.Fatalf("validateBolt accepted a torn copy (%s) as clean", name)
			}
		})
	}
}

// TestValidateBoltHighBitPgidRejected_DAR70 is the regression for the integer-
// safety bug Codex caught in the high-water-mark guard: a torn copy whose active
// meta carries a VALID checksum but a pgid with the high bit set would, under a
// naive int64(pgid) cast, become negative and silently PASS the bounds check —
// then get mmap-walked and accepted as clean. The fix compares in uint64 space.
// The other torn cases all use normal (small) pgids, so only this one exercises
// the signed-overflow path.
func TestValidateBoltHighBitPgidRejected_DAR70(t *testing.T) {
	root := t.TempDir()
	good := filepath.Join(root, "good.db")
	makeBolt(t, good)
	// Grow so the file spans several real pages and stays a clean multiple of the
	// page size (no truncation/misalignment that an earlier guard would catch).
	live, err := bolt.Open(good, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := live.Update(func(tx *bolt.Tx) error {
		b, _ := tx.CreateBucketIfNotExists([]byte("Big"))
		return b.Put([]byte("k"), bytes.Repeat([]byte("x"), 4096))
	}); err != nil {
		t.Fatalf("grow: %v", err)
	}
	live.Close()

	raw, err := os.ReadFile(good)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	pageSize := int(binary.LittleEndian.Uint32(raw[boltPageHeaderSize+metaOffPageSize:]))
	if pageSize < 512 {
		t.Fatalf("implausible page size %d", pageSize)
	}

	// Tamper BOTH meta pages: set the high-water pgid to a value with the high bit
	// set (negative as int64) and recompute the FNV-1a checksum so the meta still
	// parses as valid — forcing the bounds check (not the checksum check) to be the
	// line of defense.
	const highBitPgid uint64 = 1 << 63 // 0x8000000000000000
	for _, pageOff := range []int{0, pageSize} {
		metaStart := pageOff + boltPageHeaderSize
		binary.LittleEndian.PutUint64(raw[metaStart+metaOffPgid:], highBitPgid)
		h := fnv.New64a()
		_, _ = h.Write(raw[metaStart : metaStart+metaOffChecksum])
		binary.LittleEndian.PutUint64(raw[metaStart+metaOffChecksum:], h.Sum64())
	}

	p := filepath.Join(t.TempDir(), "highbit.db")
	if err := os.WriteFile(p, raw, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Without the uint64 comparison this returns nil (accepts the torn copy) — the
	// bug. With the fix it rejects via the high-water-mark guard.
	if err := validateBolt(p, time.Second); err == nil {
		t.Fatalf("validateBolt accepted a high-bit-pgid torn copy as clean")
	}
}

// TestSnapshotRetriesThenErrorsOnPersistentTear: hand Snapshot a source that is
// always torn (a static corrupt file); it must retry then error cleanly without
// panicking, leaving no validated temp file behind.
func TestSnapshotRetriesThenErrorsOnPersistentTear(t *testing.T) {
	root := t.TempDir()
	good := filepath.Join(root, "good.db")
	makeBolt(t, good)
	raw, err := os.ReadFile(good)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	torn := filepath.Join(root, "torn.db")
	if err := os.WriteFile(torn, raw[:len(raw)/3], 0o600); err != nil { // truncated => always torn
		t.Fatalf("write torn: %v", err)
	}

	snap := NewBoltSnapshotter()
	out, err := snap.Snapshot(context.Background(), torn, root)
	if err == nil {
		t.Fatalf("expected Snapshot to error on a persistently torn source; got path %q", out)
	}
	if out != "" {
		t.Fatalf("Snapshot returned a path on failure: %q", out)
	}
}

// zeroInterior zeroes every page after the two meta pages, leaving the meta
// pages (and thus the page-size header + meta checksum) intact.
func zeroInterior(raw []byte) []byte {
	out := append([]byte{}, raw...)
	if len(out) < 28 {
		return out
	}
	pageSize := int(out[24]) | int(out[25])<<8 | int(out[26])<<16 | int(out[27])<<24
	if pageSize <= 0 || 2*pageSize >= len(out) {
		return out
	}
	for i := 2 * pageSize; i < len(out); i++ {
		out[i] = 0
	}
	return out
}

// failingSnapshotter is injected to confirm the archiver surfaces snapshot
// errors during Phase A (Stage).
type failingSnapshotter struct{}

func (failingSnapshotter) Snapshot(context.Context, string, string) (string, error) {
	return "", io.ErrUnexpectedEOF
}

func TestArchivePropagatesSnapshotError(t *testing.T) {
	root := t.TempDir()
	makeBolt(t, filepath.Join(root, "x.db"))
	a := &Archiver{Snapshotter: failingSnapshotter{}}
	// Stage (Phase A) must fail; nothing is written.
	_, err := a.Stage(context.Background(), root)
	if err == nil {
		t.Fatal("expected Stage to fail when snapshotter errors")
	}
}
