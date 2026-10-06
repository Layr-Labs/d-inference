package promptcontract_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	artifacts "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/artifacts"
)

func TestArtifactCachePublishLocksNestedDirectories(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	manifest := fixtureNestedManifest("a/b/tokenizer.json", body)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(body)
	}))
	defer server.Close()
	root := readOnlyTempRoot(t)
	cache := newTestArtifactCache(t, root, server)

	published, err := cache.Ensure(context.Background(), manifest)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "a/b"} {
		if mode := fileMode(t, filepath.Join(published, name)).Perm(); mode != 0o500 {
			t.Fatalf("%s mode = %o, want 500", name, mode)
		}
	}

	publishedRoot, err := os.OpenRoot(published)
	if err != nil {
		t.Fatal(err)
	}
	defer publishedRoot.Close()
	if err := artifacts.MakeTreeWritable(publishedRoot); err != nil {
		t.Fatal(err)
	}
	if mode := fileMode(t, filepath.Join(published, "a", "b")).Perm(); mode != 0o700 {
		t.Fatalf("writable mode = %o, want 700", mode)
	}
}

func TestArtifactCachePublishRejectsSymlinkInStagingTree(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	manifest := fixtureNestedManifest("tokenizer.json", body)
	root := readOnlyTempRoot(t)
	outside := realTempDir(t)
	outsideMode := fileMode(t, outside).Perm()
	var injectErr error
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		entries, err := os.ReadDir(root)
		if err != nil || len(entries) != 1 {
			injectErr = errors.New("locate staging root")
			http.Error(w, "test setup", http.StatusInternalServerError)
			return
		}
		injectErr = os.Symlink(outside, filepath.Join(root, entries[0].Name(), "escape"))
		_, _ = w.Write(body)
	}))
	defer server.Close()
	cache := newTestArtifactCache(t, root, server)

	_, err := cache.Ensure(context.Background(), manifest)
	if injectErr != nil {
		t.Fatal(injectErr)
	}
	// The walk error is wrapped as text, so only the outer sentinel is in the
	// chain; the message still names the integrity failure.
	if !errors.Is(err, artifacts.ErrArtifactUnavailable) || !strings.Contains(err.Error(), artifacts.ErrArtifactIntegrity.Error()) {
		t.Fatalf("error = %v, want unavailable naming the integrity failure", err)
	}
	// The walk stops before any chmod, so the symlink target is not locked.
	if mode := fileMode(t, outside).Perm(); mode != outsideMode {
		t.Fatalf("symlink target mode = %o, want unchanged %o", mode, outsideMode)
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		t.Fatalf("cache root after rejected publish: entries=%d err=%v", len(entries), err)
	}
}

func newTestArtifactCache(t *testing.T, root string, server *httptest.Server) *artifacts.ArtifactCache {
	t.Helper()
	base, err := url.Parse(server.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	cache, err := artifacts.NewArtifactCache(artifacts.ArtifactCacheConfig{
		Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return cache
}
