package promptcontract_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	production "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestPreloadProvisionedLongModelID(t *testing.T) {
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
	manifest := fixtureNestedManifest("tokenizer.json", body)
	manifest.ModelID = strings.Repeat("m", 513)
	if err := provisioner.Reconcile([]production.Manifest{manifest}); err != nil {
		t.Fatal(err)
	}
	waitForProvision(t, provisioner, 1)
	snapshot, verified := provisioner.VerifiedPreloadArtifacts()
	if len(verified) != 1 || verified[0].ModelID != manifest.ModelID {
		t.Fatal("provisioner did not retain the long model ID")
	}
	for _, admissible := range []bool{false, true} {
		input := preload.PreloadSelectionInput{CatalogGeneration: snapshot.Generation, ChildGeneration: 1,
			Capacity: 1, Verified: verified, PubliclyAvailable: []string{manifest.ModelID},
			Published: &preload.PreloadPublishedArtifacts{CatalogGeneration: snapshot.Generation, ChildGeneration: 1, Successful: verified}}
		if admissible {
			input.Admissible = verified
		}
		policy := preload.NewPreloadActiveSet()
		key, err := policy.Reconcile(0, input)
		if err != nil {
			t.Errorf("provisioned 513-byte ID rejected (admissible=%t): %v", admissible, err)
			continue
		}
		if !slices.Equal(key.Desired, snapshot.ContractIDs) || policy.NoteDemand(0, verified[0]) != admissible {
			t.Fatal("long model ID changed full-set selection or demand eligibility")
		}
	}
}

func TestPreloadModelIDByteLimit(t *testing.T) {
	input := activeSetInput(1, 1)
	input.Verified[0].ModelID = strings.Repeat("m", (64<<20)+1)
	input.Admissible = slices.Clone(input.Verified)
	policy := preload.NewPreloadActiveSet()
	if _, err := policy.Reconcile(0, input); err == nil {
		t.Fatal("model ID exceeding registration's body ceiling accepted")
	}
	if policy.NoteDemand(0, input.Verified[0]) {
		t.Fatal("oversized model ID retained as demand")
	}
}
