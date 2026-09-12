package promptcontract

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestArtifactCacheOwnsConfiguredOrigin(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/original/pinned/tokenizer.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/original/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	base.Path = "/caller-reused-url/"
	if _, err := cache.Ensure(context.Background(), fixtureManifest(map[string][]byte{"tokenizer.json": body})); err != nil {
		t.Fatalf("caller URL mutation changed configured artifact source: %v", err)
	}
}

func TestArtifactPublicationLoserRemovesReadOnlyStaging(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		entered <- struct{}{}
		select {
		case <-release:
			_, _ = w.Write(body)
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	defer unblock()
	base, _ := url.Parse(server.URL + "/")
	root := readOnlyTempRoot(t)
	manifest := fixtureNestedManifest("nested/tokenizer.json", body)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	results := make(chan error, 2)
	for range 2 {
		cache, err := NewArtifactCache(ArtifactCacheConfig{Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true})
		if err != nil {
			t.Fatal(err)
		}
		go func() { _, err := cache.Ensure(ctx, manifest); results <- err }()
	}
	for range 2 {
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal("both independent publishers did not reach their download")
		}
	}
	unblock()
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || strings.HasPrefix(entries[0].Name(), ".tmp-") {
		t.Fatalf("publication retained staging alongside the winner: %v", entries)
	}
	if mode := fileMode(t, filepath.Join(root, entries[0].Name())).Perm(); mode != 0o500 {
		t.Fatalf("winner permissions changed during loser cleanup: %o", mode)
	}
}

func TestProvisionerOwnsQueuedManifestFiles(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	started := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/pinned/first.json" {
			close(started)
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		_, _ = w.Write(body)
	}))
	defer server.Close()
	defer unblock()
	base, _ := url.Parse(server.URL + "/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := NewProvisioner(context.Background(), cache, ProvisionerConfig{MaxConcurrent: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()
	manifests := []Manifest{fixtureNestedManifest("first.json", body), fixtureNestedManifest("second.json", body)}
	manifests[0].ModelID, manifests[1].ModelID = "first", "second"
	if err := provisioner.Reconcile(manifests); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first download did not start")
	}
	// One worker is blocked above: the second file has not been read by Ensure.
	// Callers can reuse their manifest backing arrays after Reconcile returns.
	manifests[1].Files[0].Path = "caller-mutated.json"
	unblock()
	waitForProvision(t, provisioner, 2)
	status, ok := provisioner.Status("second")
	if !ok || filepath.Base(status.Path) != status.PromptContractID {
		t.Fatalf("queued artifact changed after its contract was recorded: %+v", status)
	}
	if _, err := os.Stat(filepath.Join(status.Path, "second.json")); err != nil {
		t.Fatalf("original queued artifact not published: %v", err)
	}
}

func TestArtifactCacheValidatesEveryJoiningManifest(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	manifest := fixtureManifest(map[string][]byte{"tokenizer.json": body})
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan struct{})
	go func() { defer close(finished); _, _ = cache.Ensure(ctx, manifest) }()
	defer func() { cancel(); <-finished }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("leader download did not start")
	}
	invalid := manifest
	invalid.AggregateSHA256 = strings.Repeat("0", 64)
	follower, cancelFollower := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancelFollower()
	if _, err := cache.Ensure(follower, invalid); !errors.Is(err, ErrArtifactIntegrity) {
		t.Fatalf("joining manifest escaped its integrity check: %v", err)
	}
}
