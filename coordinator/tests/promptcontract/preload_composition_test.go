package promptcontract_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestPreloadControllerComposesRealOwnersForEmptyCatalog(t *testing.T) {
	base, err := url.Parse("https://artifacts.invalid/")
	if err != nil {
		t.Fatal(err)
	}
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache, promptcontract.ProvisionerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()
	if err := provisioner.Reconcile(nil); err != nil {
		t.Fatal(err)
	}
	supervisor, _ := startSupervisorHelper(t)
	waitForSupervisor(t, supervisor, func(status promptcontract.SupervisorStatus) bool { return status.Ready })
	controller, err := promptcontract.NewPreloadController(provisioner, supervisor, promptcontract.PreloadControllerConfig{PollInterval: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	controller.Start(context.Background())
	defer controller.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		status := controller.Status()
		// An empty verified set closes participation without an empty preload.
		// The controller reports this reason only after it has observed both the
		// real catalog generation and the real running child generation.
		if status.LastError == "no verified prompt contracts" {
			if status.Ready || status.CatalogGeneration != 0 || status.ChildGeneration != 0 || status.ContractCount != 0 ||
				status.Runs != 0 || status.Failures != 0 || controller.ReadyFor(strings.Repeat("a", 64)) {
				t.Fatalf("composed empty-catalog handoff was not fenced: %+v", status)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("composed controller did not observe the empty catalog: %+v", controller.Status())
}

func TestPreloadControllerUsesActualProvisioningCatalogBound(t *testing.T) {
	body := []byte(`{"version":"1.0"}`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(body) }))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache, promptcontract.ProvisionerConfig{MaxModels: 129, MaxConcurrent: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()
	manifests := make([]promptcontract.Manifest, 129)
	for i := range manifests {
		manifests[i] = fixtureNestedManifest("tokenizer.json", body)
		manifests[i].ModelID = fmt.Sprintf("model-%03d", i)
	}
	// Publish the shared artifact before the asynchronous catalog pass. The
	// catalog-size regression must not depend on a three-second download/fsync
	// deadline while an unrelated builder is active.
	setup, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if _, err := cache.Ensure(setup, manifests[0]); err != nil {
		t.Fatal(err)
	}
	if err := provisioner.Reconcile(manifests); err != nil {
		t.Fatal(err)
	}
	waitForProvision(t, provisioner, 129)
	supervisor, _ := startSupervisorHelper(t)
	waitForSupervisor(t, supervisor, func(s promptcontract.SupervisorStatus) bool { return s.Ready })
	// The public assembly must derive its bound from the actual provisioner,
	// rather than retain the default128 or a foreign caller’s bound1.
	controller, err := promptcontract.NewPreloadController(provisioner, supervisor, promptcontract.PreloadControllerConfig{MaxCatalogModels: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer controller.Close()
	controller.Start(context.Background())
	// This real supervisor fixture intentionally has no preload endpoint. A
	// failed attempt proves selection reached IO; invalid selection issues none.
	deadline := time.Now().Add(3 * time.Second)
	status := controller.Status()
	for status.Failures == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
		status = controller.Status()
	}
	if status.Failures == 0 || status.LastError != "preload_failed" {
		t.Fatalf("actual129-model provisioning bound not handed off: %+v", status)
	}
	snapshot, v := provisioner.VerifiedPreloadArtifacts()
	if snapshot.Counts.Ready != 129 || len(v) != 129 || len(snapshot.ContractIDs) != 1 {
		t.Fatalf("verified catalog was pruned: %+v tuples=%d", snapshot, len(v))
	}
}
