package promptcontract

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestArtifactCacheDownloadsOnceAndPublishesReadOnly(t *testing.T) {
	files := map[string][]byte{
		"config.json":         []byte(`{"model_type":"test"}`),
		"tokenizer.json":      []byte(`{"version":"1.0"}`),
		"chat_template.jinja": []byte(`{{ messages[0].content }}`),
		"model.safetensors":   []byte("weight"),
	}
	manifest := fixtureManifest(files)
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		name := strings.TrimPrefix(r.URL.Path, "/models/pinned/")
		body, ok := files[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/models/")
	root := realTempDir(t)
	t.Cleanup(func() {
		rootHandle, err := os.OpenRoot(root)
		if err == nil {
			makeTreeWritable(rootHandle)
			_ = rootHandle.Close()
		}
	})
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root:       root,
		BaseURL:    base,
		HTTPClient: server.Client(),
		AllowHTTP:  true,
	})
	if err != nil {
		t.Fatal(err)
	}

	const callers = 12
	var wg sync.WaitGroup
	results := make(chan string, callers)
	errors := make(chan error, callers)
	for range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, err := cache.Ensure(context.Background(), manifest)
			results <- result
			errors <- err
		}()
	}
	wg.Wait()
	close(results)
	close(errors)
	var published string
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	for result := range results {
		if published == "" {
			published = result
		} else if published != result {
			t.Fatalf("singleflight published different paths: %q and %q", published, result)
		}
	}
	if requests.Load() != 3 {
		t.Fatalf("downloaded %d files, want one request per three prompt artifacts", requests.Load())
	}
	if mode := fileMode(t, published).Perm(); mode != 0o500 {
		t.Fatalf("published directory mode = %o, want 0500", mode)
	}
	for _, name := range []string{"config.json", "tokenizer.json", "chat_template.jinja", MetadataFile} {
		if mode := fileMode(t, filepath.Join(published, name)).Perm(); mode != 0o400 {
			t.Fatalf("%s mode = %o, want 0400", name, mode)
		}
	}
	if _, err := os.Stat(filepath.Join(published, "model.safetensors")); !os.IsNotExist(err) {
		t.Fatalf("weight file was downloaded: %v", err)
	}
	configPath := filepath.Join(published, "config.json")
	if err := os.Chmod(configPath, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte(`{"model_type":"evil"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Ensure(context.Background(), manifest); err == nil {
		t.Fatal("tampered published artifact unexpectedly accepted")
	}
}

func TestArtifactCacheFailsClosedOnDigestMismatchAndSymlink(t *testing.T) {
	files := map[string][]byte{
		"config.json":         []byte(`{"model_type":"test"}`),
		"tokenizer.json":      []byte(`{"version":"1.0"}`),
		"chat_template.jinja": []byte(`{{ messages[0].content }}`),
	}
	manifest := fixtureManifest(files)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("tampered"))
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	root := realTempDir(t)
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Ensure(context.Background(), manifest); err == nil {
		t.Fatal("digest mismatch unexpectedly published")
	}

	artifacts, _ := PromptArtifacts(manifest.Files)
	contractID, _ := ContractID(artifacts, CurrentVersions())
	outside := realTempDir(t)
	if err := os.Symlink(outside, filepath.Join(root, contractID)); err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Ensure(context.Background(), manifest); err == nil {
		t.Fatal("symlinked destination unexpectedly accepted")
	}
}

func TestArtifactCacheRejectsSymlinkedRootAndRootAncestor(t *testing.T) {
	files := map[string][]byte{"tokenizer.json": []byte(`{"version":"1.0"}`)}
	manifest := fixtureManifest(files)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(files["tokenizer.json"])
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")

	for _, root := range func() []string {
		parent := realTempDir(t)
		outside := realTempDir(t)
		rootLink := filepath.Join(parent, "root-link")
		if err := os.Symlink(outside, rootLink); err != nil {
			t.Fatal(err)
		}
		ancestorTarget := realTempDir(t)
		ancestorLink := filepath.Join(parent, "ancestor-link")
		if err := os.Symlink(ancestorTarget, ancestorLink); err != nil {
			t.Fatal(err)
		}
		return []string{rootLink, filepath.Join(ancestorLink, "cache")}
	}() {
		cache, err := NewArtifactCache(ArtifactCacheConfig{
			Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := cache.Ensure(context.Background(), manifest); err == nil {
			t.Fatalf("symlinked artifact root %q unexpectedly accepted", root)
		}
	}
}

func TestArtifactCacheRejectsAncestorReplacementRaces(t *testing.T) {
	for _, replaced := range []string{"ancestor", "ancestor/nested"} {
		t.Run(strings.ReplaceAll(replaced, "/", "-"), func(t *testing.T) {
			body := []byte(`{"version":"1.0"}`)
			manifest := fixtureNestedManifest("ancestor/nested/tokenizer.json", body)
			root := realTempDir(t)
			outside := realTempDir(t)
			outsideFile := filepath.Join(outside, "tokenizer.json")
			if err := os.WriteFile(outsideFile, []byte("outside"), 0o600); err != nil {
				t.Fatal(err)
			}
			var replacementErr error
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				entries, err := os.ReadDir(root)
				if err != nil || len(entries) != 1 {
					replacementErr = fmt.Errorf("locate staging root: entries=%d err=%v", len(entries), err)
					http.Error(w, "test setup", http.StatusInternalServerError)
					return
				}
				target := filepath.Join(root, entries[0].Name(), filepath.FromSlash(replaced))
				if err := os.RemoveAll(target); err != nil {
					replacementErr = err
				} else if err := os.Symlink(outside, target); err != nil {
					replacementErr = err
				}
				_, _ = w.Write(body)
			}))
			defer server.Close()
			base, _ := url.Parse(server.URL + "/")
			cache, err := NewArtifactCache(ArtifactCacheConfig{
				Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := cache.Ensure(context.Background(), manifest); err == nil {
				t.Fatal("symlink replacement race unexpectedly published")
			}
			if replacementErr != nil {
				t.Fatal(replacementErr)
			}
			contents, err := os.ReadFile(outsideFile)
			if err != nil || string(contents) != "outside" {
				t.Fatalf("outside target was modified: contents=%q err=%v", contents, err)
			}
		})
	}
}

func TestArtifactCacheDownloadDeadline(t *testing.T) {
	files := map[string][]byte{"tokenizer.json": []byte(`{"version":"1.0"}`)}
	manifest := fixtureManifest(files)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write(files["tokenizer.json"])
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root:            realTempDir(t),
		BaseURL:         base,
		HTTPClient:      server.Client(),
		AllowHTTP:       true,
		DownloadTimeout: 20 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if _, err := cache.Ensure(context.Background(), manifest); err == nil {
		t.Fatal("deadline unexpectedly succeeded")
	}
	if elapsed := time.Since(started); elapsed > 150*time.Millisecond {
		t.Fatalf("artifact deadline was not bounded: %s", elapsed)
	}
}

func TestArtifactCacheRejectsCrossOriginRedirectBeforeFollowing(t *testing.T) {
	files := map[string][]byte{"tokenizer.json": []byte(`{"version":"1.0"}`)}
	manifest := fixtureManifest(files)
	var targetRequests atomic.Int64
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		targetRequests.Add(1)
		_, _ = w.Write(files["tokenizer.json"])
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+r.URL.Path, http.StatusFound)
	}))
	defer source.Close()
	base, _ := url.Parse(source.URL + "/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root: realTempDir(t), BaseURL: base, HTTPClient: source.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = cache.Ensure(context.Background(), manifest)
	if !errors.Is(err, ErrArtifactIntegrity) {
		t.Fatalf("cross-origin redirect error = %v, want integrity failure", err)
	}
	if targetRequests.Load() != 0 {
		t.Fatalf("cross-origin redirect was followed %d times", targetRequests.Load())
	}
}

func fixtureManifest(contents map[string][]byte) Manifest {
	files := make([]Artifact, 0, len(contents))
	for name, contents := range contents {
		digest := sha256.Sum256(contents)
		role := "weight"
		switch name {
		case "config.json":
			role = "config"
		case "tokenizer.json":
			role = "tokenizer"
		case "chat_template.jinja":
			role = "template"
		}
		files = append(files, Artifact{
			Path: name, Role: role, SizeBytes: int64(len(contents)), SHA256: hex.EncodeToString(digest[:]),
		})
	}
	slices.SortFunc(files, func(a, b Artifact) int {
		if result := strings.Compare(a.Path, b.Path); result != 0 {
			return result
		}
		return strings.Compare(a.SHA256, b.SHA256)
	})
	aggregate := sha256.New()
	for _, file := range files {
		digest, _ := hex.DecodeString(file.SHA256)
		_, _ = aggregate.Write(digest)
	}
	return Manifest{
		ModelID: "fixture-model", ModelType: "test", R2Prefix: "pinned",
		AggregateSHA256: hex.EncodeToString(aggregate.Sum(nil)), Files: files,
	}
}

func fixtureNestedManifest(name string, contents []byte) Manifest {
	digest := sha256.Sum256(contents)
	file := Artifact{
		Path: name, Role: "tokenizer", SizeBytes: int64(len(contents)),
		SHA256: hex.EncodeToString(digest[:]),
	}
	aggregate := sha256.Sum256(digest[:])
	return Manifest{
		ModelID: "fixture-nested", R2Prefix: "pinned",
		AggregateSHA256: hex.EncodeToString(aggregate[:]),
		Files:           []Artifact{file},
	}
}

func fileMode(t *testing.T, name string) os.FileMode {
	t.Helper()
	info, err := os.Stat(name)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode()
}

func realTempDir(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}
