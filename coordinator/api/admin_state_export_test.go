package api

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"filippo.io/age"
	bolt "go.etcd.io/bbolt"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// notZip reports whether b is NOT a zip (no PK\x03\x04 magic). A negative-path
// response (401/403/404/412/500) must contain ZERO archive bytes.
func notZip(b []byte) bool {
	return !bytes.HasPrefix(b, []byte("PK\x03\x04"))
}

const stateExportAdminKey = "dar70-admin-key"

// newStateExportServer builds a real Server with the admin key set, wired to a
// fresh export root. It returns the httptest server URL and the export root.
func newStateExportServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetAdminKey(stateExportAdminKey)

	root := buildStateExportRoot(t)
	t.Setenv(envStateExportRoot, root)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, root
}

// buildStateExportRoot lays down a representative /data tree with a real bbolt db.
func buildStateExportRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	writeFile(t, filepath.Join(root, "step-ca", "config", "ca.json"), `{"authority":{}}`)
	writeFile(t, filepath.Join(root, "step-ca", "secrets", "password"), "eigeninference-step-ca")
	writeFile(t, filepath.Join(root, "step-ca", "certs", "root_ca.crt"), "ROOT")
	writeFile(t, filepath.Join(root, "step-ca", "certs", "intermediate_ca.crt"), "INT")
	writeFile(t, filepath.Join(root, "step-ca", "certs", "intermediate_ca_key"), "INTKEY")

	writeFile(t, filepath.Join(root, "micromdm", "push.crt"), "PUSH")
	writeFile(t, filepath.Join(root, "micromdm", "push.key"), "PUSHKEY")
	writeFile(t, filepath.Join(root, "micromdm", "config"), "CFG")
	writeFile(t, filepath.Join(root, "micromdm", ".push_imported"), "")
	seedBolt(t, filepath.Join(root, "micromdm", "micromdm.db"))

	writeFile(t, filepath.Join(root, "step-ca.log"), "log")
	writeFile(t, filepath.Join(root, "micromdm", "micromdm.log"), "log")

	return root
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func seedBolt(t *testing.T, path string) {
	t.Helper()
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("Devices"))
		if err != nil {
			return err
		}
		return b.Put([]byte("serial-1"), []byte("payload-1"))
	}); err != nil {
		t.Fatal(err)
	}
}

func getExport(t *testing.T, url, bearer string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url+"/v1/admin/state-export", nil)
	if err != nil {
		t.Fatal(err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func zipEntries(t *testing.T, b []byte) map[string][]byte {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		t.Fatalf("open zip: %v", err)
	}
	out := map[string][]byte{}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		rc, _ := f.Open()
		data, _ := io.ReadAll(rc)
		rc.Close()
		out[f.Name] = data
	}
	return out
}

// assertNoArchiveBytes reads the whole body and fails if it looks like a zip.
func assertNoArchiveBytes(t *testing.T, resp *http.Response) {
	t.Helper()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if !notZip(body) {
		t.Fatalf("negative response (%d) leaked archive bytes (%d bytes, zip magic present)",
			resp.StatusCode, len(body))
	}
}

// (a) 404 when the master switch is unset — and no archive bytes.
func TestStateExport_DisabledReturns404_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	// envStateExportEnabled deliberately not set.
	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("disabled: got %d, want 404", resp.StatusCode)
	}
	assertNoArchiveBytes(t, resp)
}

// Disabled + missing/wrong admin key still 404 — the route is invisible
// regardless of auth (master switch precedes auth).
func TestStateExport_DisabledMasksAuth404_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	// envStateExportEnabled deliberately not set.
	for _, key := range []string{"", "wrong-key"} {
		resp := getExport(t, ts.URL, key)
		if resp.StatusCode != http.StatusNotFound {
			resp.Body.Close()
			t.Fatalf("disabled with key=%q: got %d, want 404", key, resp.StatusCode)
		}
		assertNoArchiveBytes(t, resp)
		resp.Body.Close()
	}
}

// (b) 403 with missing/wrong admin key; success with the correct key. Negative
// responses must contain zero archive bytes.
func TestStateExport_AdminAuth_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportAllowPlaintext, "true")

	// Missing key.
	resp := getExport(t, ts.URL, "")
	if resp.StatusCode != http.StatusForbidden {
		resp.Body.Close()
		t.Fatalf("missing key: got %d, want 403", resp.StatusCode)
	}
	assertNoArchiveBytes(t, resp)
	resp.Body.Close()

	// Wrong key.
	resp = getExport(t, ts.URL, "wrong-key")
	if resp.StatusCode != http.StatusForbidden {
		resp.Body.Close()
		t.Fatalf("wrong key: got %d, want 403", resp.StatusCode)
	}
	assertNoArchiveBytes(t, resp)
	resp.Body.Close()

	// Correct key.
	resp = getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("correct key: got %d, want 200", resp.StatusCode)
	}
}

// (c) 412 when no recipient and plaintext not allowed — and no archive bytes.
func TestStateExport_PreconditionFailed_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	t.Setenv(envStateExportEnabled, "true")
	// No recipient, no plaintext allowance.
	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPreconditionFailed {
		t.Fatalf("got %d, want 412", resp.StatusCode)
	}
	assertNoArchiveBytes(t, resp)
}

// HTTP-level root-missing -> 500 with no archive bytes (root resolves to a path
// that does not exist).
func TestStateExport_RootMissing500_DAR70(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetAdminKey(stateExportAdminKey)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	t.Setenv(envStateExportRoot, filepath.Join(t.TempDir(), "does-not-exist"))
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportAllowPlaintext, "true")

	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("missing root: got %d, want 500", resp.StatusCode)
	}
	assertNoArchiveBytes(t, resp)
}

// resolveStateExportRoot precedence:
// EIGENINFERENCE_STATE_EXPORT_ROOT -> USER_PERSISTENT_DATA_PATH -> /mnt/disks/userdata.
func TestResolveStateExportRootPrecedence_DAR70(t *testing.T) {
	// Default when nothing is set.
	t.Setenv(envStateExportRoot, "")
	t.Setenv("USER_PERSISTENT_DATA_PATH", "")
	if got := resolveStateExportRoot(); got != "/mnt/disks/userdata" {
		t.Fatalf("default = %q, want /mnt/disks/userdata", got)
	}
	// USER_PERSISTENT_DATA_PATH wins over the hardcoded default.
	t.Setenv("USER_PERSISTENT_DATA_PATH", "/persist")
	if got := resolveStateExportRoot(); got != "/persist" {
		t.Fatalf("with USER_PERSISTENT_DATA_PATH = %q, want /persist", got)
	}
	// Explicit override wins over everything.
	t.Setenv(envStateExportRoot, "/explicit")
	if got := resolveStateExportRoot(); got != "/explicit" {
		t.Fatalf("with override = %q, want /explicit", got)
	}
}

// HTTP-level encrypted export through a SYMLINKED root still captures children
// (mirrors prod start.sh `ln -sfn $PERSIST /data`).
func TestStateExport_SymlinkedRoot_DAR70(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetAdminKey(stateExportAdminKey)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	real := buildStateExportRoot(t)
	link := filepath.Join(t.TempDir(), "data-link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	t.Setenv(envStateExportRoot, link)
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportAllowPlaintext, "true")

	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("symlinked root: got %d, want 200", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	files := zipEntries(t, body)
	if _, ok := files["micromdm/micromdm.db"]; !ok {
		t.Fatal("symlinked-root archive missing micromdm.db (EvalSymlinks not applied)")
	}
}

// (d) plaintext allowed -> valid zip; tree matches, *.log excluded,
// .push_imported included, bolt db opens ReadOnly with intact buckets/keys.
func TestStateExport_PlaintextZip_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportAllowPlaintext, "true")

	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/zip" {
		t.Fatalf("content-type = %q, want application/zip", ct)
	}
	if cd := resp.Header.Get("Content-Disposition"); !bytes.Contains([]byte(cd), []byte(".zip\"")) {
		t.Fatalf("content-disposition = %q, want a .zip filename", cd)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	files := zipEntries(t, body)

	for _, name := range []string{
		"step-ca/config/ca.json",
		"step-ca/secrets/password",
		"micromdm/push.crt",
		"micromdm/.push_imported",
		"micromdm/micromdm.db",
	} {
		if _, ok := files[name]; !ok {
			t.Errorf("missing %q in archive", name)
		}
	}
	for _, name := range []string{"step-ca.log", "micromdm/micromdm.log"} {
		if _, ok := files[name]; ok {
			t.Errorf("%q should be excluded", name)
		}
	}

	// The bolt db in the zip opens ReadOnly with intact data.
	dbBytes := files["micromdm/micromdm.db"]
	tmp := filepath.Join(t.TempDir(), "out.db")
	if err := os.WriteFile(tmp, dbBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(tmp, 0o400, &bolt.Options{ReadOnly: true, Timeout: 2 * time.Second})
	if err != nil {
		t.Fatalf("open extracted db: %v", err)
	}
	defer db.Close()
	if err := db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("Devices"))
		if b == nil {
			t.Fatal("Devices bucket missing")
		}
		if got := b.Get([]byte("serial-1")); !bytes.Equal(got, []byte("payload-1")) {
			t.Fatalf("serial-1 = %q, want payload-1", got)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// (e) recipient set -> output is an age stream that decrypts to a valid zip.
func TestStateExport_EncryptedToRecipient_DAR70(t *testing.T) {
	ts, _ := newStateExportServer(t)
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportRecipient, id.Recipient().String())

	resp := getExport(t, ts.URL, stateExportAdminKey)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/octet-stream" {
		t.Fatalf("content-type = %q, want application/octet-stream", ct)
	}
	if cd := resp.Header.Get("Content-Disposition"); !bytes.Contains([]byte(cd), []byte(".zip.age\"")) {
		t.Fatalf("content-disposition = %q, want a .zip.age filename", cd)
	}

	cipher, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	// Must NOT be a plain zip (PK\x03\x04 magic).
	if bytes.HasPrefix(cipher, []byte("PK\x03\x04")) {
		t.Fatal("output looks like a plain zip — encryption did not happen")
	}

	dr, err := age.Decrypt(bytes.NewReader(cipher), id)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	plain, err := io.ReadAll(dr)
	if err != nil {
		t.Fatalf("read decrypted: %v", err)
	}
	files := zipEntries(t, plain)
	if _, ok := files["micromdm/micromdm.db"]; !ok {
		t.Fatal("decrypted archive missing micromdm.db")
	}
	if _, ok := files["step-ca/config/ca.json"]; !ok {
		t.Fatal("decrypted archive missing ca.json")
	}
}

// (f) consistency: continuous writes to the LIVE db during export; the snapshot
// in the (decrypted) zip must open and pass Check().
func TestStateExport_ConsistencyUnderWrites_DAR70(t *testing.T) {
	ts, root := newStateExportServer(t)
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(envStateExportEnabled, "true")
	t.Setenv(envStateExportRecipient, id.Recipient().String())

	// Open the live db RW and hammer it with writes (mirrors MicroMDM).
	dbPath := filepath.Join(root, "micromdm", "micromdm.db")
	live, err := bolt.Open(dbPath, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()

	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
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
				return b.Put([]byte("k"), []byte(time.Now().String()))
			})
		}
	}()

	resp := getExport(t, ts.URL, stateExportAdminKey)
	cipher, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	cancel()
	wg.Wait()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}
	dr, err := age.Decrypt(bytes.NewReader(cipher), id)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	plain, err := io.ReadAll(dr)
	if err != nil {
		t.Fatal(err)
	}
	files := zipEntries(t, plain)
	dbBytes, ok := files["micromdm/micromdm.db"]
	if !ok {
		t.Fatal("snapshot db missing from archive")
	}
	tmp := filepath.Join(t.TempDir(), "snap.db")
	if err := os.WriteFile(tmp, dbBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	// Validate with a recover-wrapped walk, NOT tx.Check(): on a genuinely torn
	// copy Check() panics in an internal goroutine and would crash the whole
	// `go test` binary instead of failing this test.
	if err := validateBoltCopy(tmp); err != nil {
		t.Fatalf("snapshot in archive failed validation: %v", err)
	}
}

// validateBoltCopy opens a bolt copy ReadOnly and walks every bucket, recovering
// from any panic (a torn copy can fault the mmap walk). It mirrors the
// production validator in package stateexport but lives here because that
// validator is unexported.
func validateBoltCopy(path string) (retErr error) {
	defer func() {
		if rec := recover(); rec != nil {
			retErr = fmt.Errorf("bolt validation panicked (torn/corrupt copy): %v", rec)
		}
	}()
	db, err := bolt.Open(path, 0o400, &bolt.Options{ReadOnly: true, Timeout: 2 * time.Second})
	if err != nil {
		return err
	}
	defer db.Close()
	return db.View(func(tx *bolt.Tx) error {
		return tx.ForEach(func(_ []byte, b *bolt.Bucket) error {
			return b.ForEach(func(_, _ []byte) error { return nil })
		})
	})
}
