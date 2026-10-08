package promptcontract_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
	production "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestProvisionerVerifiedPreloadSnapshotIsCoherentDetachedAndFull(t *testing.T) {
	backing := strings.Repeat("a", 1<<20)
	model, hash := backing[100:110], backing[200:264]
	p := catalog.New()
	for range 37 {
		p.Replace([]catalog.Status{
			{ModelID: model, ArtifactReady: true, PromptContractID: hash, ModelAggregateSHA256: hash, Path: "/private/fixture"},
			{ModelID: "other", ArtifactReady: true, PromptContractID: hash, ModelAggregateSHA256: strings.Repeat("b", 64)},
			{ModelID: "pending", PromptContractID: strings.Repeat("c", 64)},
			{ModelID: "failed", LastError: "synthetic failure"},
		})
	}
	snapshot, artifacts := p.VerifiedPreloadArtifacts()
	if snapshot.Generation != 37 || snapshot.Counts != (catalog.Counts{Ready: 2, Pending: 1, Failed: 1}) ||
		len(snapshot.ContractIDs) != 1 || len(artifacts) != 2 {
		t.Fatal("verified tuple snapshot pruned shared-contract models or mixed counts/generation")
	}
	first := artifacts[0]
	if first.CatalogGeneration != 37 || first.ModelID != model || first.ModelAggregateSHA256 != hash || first.PromptContractID != hash {
		t.Fatal("snapshot identity differs from the verified catalog")
	}
	if unsafe.StringData(first.ModelID) == unsafe.StringData(model) || unsafe.StringData(first.ModelAggregateSHA256) == unsafe.StringData(hash) ||
		unsafe.StringData(first.PromptContractID) == unsafe.StringData(hash) || unsafe.StringData(snapshot.ContractIDs[0]) == unsafe.StringData(hash) {
		t.Fatal("snapshot retained source backing storage")
	}
	artifacts[0].ModelID, snapshot.ContractIDs[0] = "changed", "changed"
	current, again := p.VerifiedPreloadArtifacts()
	if current.ContractIDs[0] != hash || again[0].ModelID != model {
		t.Fatal("caller mutated authoritative membership")
	}

	// The provisioner owns the closed lifecycle around the catalog handoff.
	body := []byte(`{"version":"1.0"}`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(body) }))
	defer server.Close()
	base, _ := url.Parse(server.URL + "/")
	cache, err := production.NewArtifactCache(production.ArtifactCacheConfig{
		Root: readOnlyTempRoot(t), BaseURL: base, HTTPClient: server.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := production.NewProvisioner(context.Background(), cache, production.ProvisionerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()
	if err := provisioner.Reconcile([]identity.Manifest{fixtureNestedManifest("tokenizer.json", body)}); err != nil {
		t.Fatal(err)
	}
	waitForProvision(t, provisioner, 1)
	if open, values := provisioner.VerifiedPreloadArtifacts(); open.Generation == 0 || len(values) != 1 {
		t.Fatal("open provisioner did not hand off its verified artifact")
	}
	provisioner.Close()
	if closed, values := provisioner.VerifiedPreloadArtifacts(); closed.Generation != 0 || len(values) != 0 {
		t.Fatal("closed provisioner retained selection authority")
	}
}
