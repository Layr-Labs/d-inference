package promptcontract

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProvisionerBoundsWorkAndTracksPerModelReadiness(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	var active atomic.Int64
	var maximum atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		current := active.Add(1)
		defer active.Add(-1)
		for {
			seen := maximum.Load()
			if current <= seen || maximum.CompareAndSwap(seen, current) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		_, _ = w.Write(body)
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	root := readOnlyTempRoot(t)
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root: root, BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := NewProvisioner(context.Background(), cache, ProvisionerConfig{
		MaxConcurrent: 2,
		MaxModels:     8,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()

	manifests := make([]Manifest, 4)
	for index := range manifests {
		suffix := string(rune('a' + index))
		manifests[index] = fixtureNestedManifest("tokenizer-"+suffix+".json", body)
		manifests[index].ModelID = "model-" + suffix
		manifests[index].R2Prefix = manifests[index].ModelID
	}
	if err := provisioner.Reconcile(manifests); err != nil {
		t.Fatal(err)
	}
	waitForProvision(t, provisioner, 4)
	if maximum.Load() > 2 {
		t.Fatalf("provision concurrency = %d, want <= 2", maximum.Load())
	}
	for _, manifest := range manifests {
		status, ok := provisioner.Status(manifest.ModelID)
		if !ok || !status.ArtifactReady || status.Path == "" || status.LastError != "" {
			t.Fatalf("model %q status = %+v, found=%t", manifest.ModelID, status, ok)
		}
	}
}

func TestProvisionerCancelsObsoleteCatalogPass(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	slowStarted := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow/tokenizer.json" {
			select {
			case <-slowStarted:
			default:
				close(slowStarted)
			}
			<-r.Context().Done()
			return
		}
		_, _ = w.Write(body)
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	root := readOnlyTempRoot(t)
	cache, err := NewArtifactCache(ArtifactCacheConfig{
		Root:            root,
		BaseURL:         base,
		HTTPClient:      server.Client(),
		AllowHTTP:       true,
		DownloadTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := NewProvisioner(context.Background(), cache, ProvisionerConfig{
		MaxConcurrent: 1,
		MaxModels:     8,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()

	slow := fixtureNestedManifest("tokenizer.json", body)
	slow.ModelID = "slow"
	slow.R2Prefix = "slow"
	if err := provisioner.Reconcile([]Manifest{slow}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-slowStarted:
	case <-time.After(time.Second):
		t.Fatal("slow provision did not start")
	}

	fast := fixtureNestedManifest("tokenizer.json", body)
	fast.ModelID = "fast"
	fast.R2Prefix = "fast"
	if err := provisioner.Reconcile([]Manifest{fast}); err != nil {
		t.Fatal(err)
	}
	waitForProvision(t, provisioner, 1)
	if _, ok := provisioner.Status("slow"); ok {
		t.Fatal("obsolete model status survived catalog reconcile")
	}
	status, ok := provisioner.Status("fast")
	if !ok || !status.ArtifactReady {
		t.Fatalf("fast model status = %+v, found=%t", status, ok)
	}
}

func TestProvisionerCountsAllStatesWithoutIdentity(t *testing.T) {
	sharedContract := strings.Repeat("a", 64)
	provisioner := &Provisioner{generation: 7, statuses: map[string]ProvisionStatus{
		"private-ready":   {ArtifactReady: true, PromptContractID: sharedContract},
		"private-shared":  {ArtifactReady: true, PromptContractID: sharedContract},
		"private-pending": {},
		"private-failed":  {LastError: "private filesystem detail"},
	}}
	counts := provisioner.Counts()
	if counts.Ready != 2 || counts.Pending != 1 || counts.Failed != 1 {
		t.Fatalf("counts=%+v", counts)
	}
	snapshot := provisioner.Snapshot()
	if snapshot.Generation != 7 || snapshot.Counts != counts ||
		len(snapshot.ContractIDs) != 1 || snapshot.ContractIDs[0] != sharedContract {
		t.Fatalf("snapshot=%+v", snapshot)
	}
}

func TestProvisionerRejectClosesPreviousCatalogGeneration(t *testing.T) {
	contractID := strings.Repeat("a", 64)
	provisioner := &Provisioner{
		maxModels:  8,
		generation: 4,
		statuses: map[string]ProvisionStatus{
			"old-model": {
				ArtifactReady: true, PromptContractID: contractID,
				ModelAggregateSHA256: strings.Repeat("b", 64),
			},
		},
	}
	if err := provisioner.Reconcile([]Manifest{{ModelID: "invalid"}}); err == nil {
		t.Fatal("invalid replacement catalog was accepted")
	}
	if _, ok := provisioner.Status("old-model"); ok {
		t.Fatal("old ready contract survived rejected catalog")
	}
	snapshot := provisioner.Snapshot()
	if snapshot.Generation != 5 || snapshot.Counts.Failed != 1 ||
		snapshot.Counts.Ready != 0 || len(snapshot.ContractIDs) != 0 {
		t.Fatalf("rejected catalog snapshot=%+v", snapshot)
	}
}

func waitForProvision(t *testing.T, provisioner *Provisioner, models int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		statuses := provisioner.Statuses()
		if len(statuses) == models {
			ready := true
			for _, status := range statuses {
				ready = ready && status.ArtifactReady
			}
			if ready {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("provisioning did not become ready: %+v", provisioner.Statuses())
}

func readOnlyTempRoot(t *testing.T) string {
	t.Helper()
	root := realTempDir(t)
	t.Cleanup(func() {
		rootHandle, err := os.OpenRoot(root)
		if err == nil {
			_ = makeTreeWritable(rootHandle)
			_ = rootHandle.Close()
		}
	})
	return root
}
