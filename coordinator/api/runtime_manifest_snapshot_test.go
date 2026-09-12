package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func snapshotManifest(marker string) *RuntimeManifest {
	return &RuntimeManifest{
		PythonHashes:   map[string]bool{marker: true, "disabled": false},
		RuntimeHashes:  map[string]bool{marker: true},
		TemplateHashes: map[string]map[string]bool{"mlx_metallib": {marker: true}},
	}
}

func TestRuntimeManifestPublicationOwnsInput(t *testing.T) {
	srv, _ := runtimeManifestTestServer(t)
	accepted, replacement := strings.Repeat("a", 64), strings.Repeat("b", 64)
	input := snapshotManifest(accepted)
	srv.SetRuntimeManifest(input)

	delete(input.PythonHashes, accepted)
	input.RuntimeHashes[replacement] = true
	delete(input.TemplateHashes["mlx_metallib"], accepted)
	input.TemplateHashes["mlx_metallib"][replacement] = true
	input.TemplateHashes["new"] = map[string]bool{replacement: true}

	ok, _ := srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{"mlx_metallib": accepted})
	if !ok {
		t.Error("caller mutation changed the already-published runtime policy")
	}
	if ok, _ := srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{"mlx_metallib": replacement}); ok {
		t.Error("caller mutation authorized an unpublished runtime hash")
	}
	w := httptest.NewRecorder()
	srv.handleRuntimeManifest(w, httptest.NewRequest(http.MethodGet, "/v1/runtime/manifest", nil))
	var response struct {
		Configured bool                `json:"configured"`
		Python     map[string]bool     `json:"python_hashes"`
		Runtime    map[string]bool     `json:"runtime_hashes"`
		Templates  map[string][]string `json:"template_hashes"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Configured || !reflect.DeepEqual(response.Python, map[string]bool{accepted: true, "disabled": false}) ||
		!reflect.DeepEqual(response.Runtime, map[string]bool{accepted: true}) ||
		!reflect.DeepEqual(response.Templates, map[string][]string{"mlx_metallib": {accepted}}) {
		t.Fatalf("public response changed after caller mutation: %+v", response)
	}
}

func TestRuntimeManifestConcurrentPublicationAndVerification(t *testing.T) {
	srv, _ := runtimeManifestTestServer(t)
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	manifests := []*RuntimeManifest{snapshotManifest(a), snapshotManifest(b), nil}
	srv.SetRuntimeManifest(manifests[0])
	start := make(chan struct{})
	var workers sync.WaitGroup
	workers.Add(5)
	go func() {
		defer workers.Done()
		<-start
		for i := 0; i < 300; i++ {
			srv.SetRuntimeManifest(manifests[i%len(manifests)])
		}
	}()
	for worker := 0; worker < 4; worker++ {
		go func() {
			defer workers.Done()
			<-start
			provider := &registry.Provider{Backend: "mlx-swift"}
			for i := 0; i < 100; i++ {
				srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{"mlx_metallib": a})
				srv.applyChallengeRuntimePolicy(provider, &protocol.AttestationResponseMessage{TemplateHashes: map[string]string{"mlx_metallib": a}})
				srv.readCache.Invalidate(runtimeManifestCacheKey)
				w := httptest.NewRecorder()
				srv.handleRuntimeManifest(w, httptest.NewRequest(http.MethodGet, "/v1/runtime/manifest", nil))
				var response struct {
					Configured bool                `json:"configured"`
					Python     map[string]bool     `json:"python_hashes"`
					Runtime    map[string]bool     `json:"runtime_hashes"`
					Templates  map[string][]string `json:"template_hashes"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
					t.Error(err)
					return
				}
				if !response.Configured {
					if response.Python != nil || response.Runtime != nil || response.Templates != nil {
						t.Error("withdrawn manifest response retained configured fields")
					}
					continue
				}
				marker := a
				if response.Python[b] {
					marker = b
				}
				if !response.Python[marker] || !response.Runtime[marker] ||
					!reflect.DeepEqual(response.Templates["mlx_metallib"], []string{marker}) {
					t.Errorf("one response mixed separate runtime policies: %+v", response)
					return
				}
			}
		}()
	}
	close(start)
	workers.Wait()
}

func TestRuntimeManifestConcurrentCommittedReleaseUnion(t *testing.T) {
	srv, _ := runtimeManifestTestServer(t)
	srv.SetRuntimeManifest(nil)
	const releases = 32
	start := make(chan struct{})
	var workers sync.WaitGroup
	for i := 1; i <= releases; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			<-start
			srv.convergeRuntimeManifestWithCommittedRelease(&store.Release{
				Version: fmt.Sprintf("0.0.%d", i), Platform: "macos-arm64",
				MetallibHash: fmt.Sprintf("%064x", i),
			}, errors.New("fixture inventory unavailable"))
		}(i)
	}
	close(start)
	workers.Wait()
	for i := 1; i <= releases; i++ {
		hash := fmt.Sprintf("%064x", i)
		if ok, _ := srv.verifyRuntimeHashesForBackend("mlx-swift", "", "", map[string]string{"mlx_metallib": hash}); !ok {
			t.Errorf("concurrent convergence lost committed release %d", i)
		}
	}
}
