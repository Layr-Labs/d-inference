package api

import (
	"bytes"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestReleasePolicyUsesCurrentInventoryFleetAndVersionFloor(t *testing.T) {
	initial := store.NewMemory(store.Config{})
	firstRegistry := registry.New(quietLogger())
	srv := NewServer(firstRegistry, initial, ServerConfig{}, quietLogger())
	defer srv.Close()
	if err := initial.SetRelease(unionReleaseRow("0.8.15", trHashA, trHashC)); err != nil {
		t.Fatal(err)
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatal(err)
	}
	previous := unionFleetProvider(t, firstRegistry, "initial-fleet", "initial-model", "0.8.15", trHashC)
	assertRuntimeApproved(t, srv, previous, "initial-model", true, "initial bindings")

	current := store.NewMemory(store.Config{})
	if err := current.SetRelease(unionReleaseRow("0.8.16", trHashB, trHashD)); err != nil {
		t.Fatal(err)
	}
	currentRegistry := registry.New(quietLogger())
	provider := unionFleetProvider(t, currentRegistry, "current-fleet", "current-model", "0.8.16", trHashD)
	var logs bytes.Buffer
	srv.store = current
	srv.registry = currentRegistry
	srv.logger = slog.New(slog.NewTextHandler(&logs, nil))
	srv.SetMinProviderVersion("0.8.17")
	srv.AddKnownBinaryHashes([]string{strings.Repeat("e", 64)})
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatal(err)
	}
	configured, hashes := srv.binaryHashPolicySnapshot()
	if !configured || !hashes[trHashB] || !hashes[strings.Repeat("e", 64)] || hashes[trHashA] {
		t.Fatalf("current inventory/manual hash union = configured:%v hashes:%v", configured, hashes)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatal(err)
	}
	assertRuntimeApproved(t, srv, provider, "current-model", false, "current minimum version")
	previous.Mu().Lock()
	previousRuntime := previous.RuntimeVerified && previous.RuntimeManifestChecked && previous.MetallibVerified
	previous.Mu().Unlock()
	if !previousRuntime {
		t.Fatal("new policy was applied to the detached initial registry")
	}
	srv.SetMinProviderVersion("")
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatal(err)
	}
	assertRuntimeApproved(t, srv, provider, "current-model", true, "current floor rollback")
	if !strings.Contains(logs.String(), "binary hashes synced from releases") {
		t.Fatalf("policy logging retained the initial logger: %s", logs.String())
	}
	response := doReq(srv, http.MethodGet, "/v1/runtime/manifest", "", "")
	if response.Code != http.StatusOK || !bytes.Contains(response.Body.Bytes(), []byte(trHashD)) || bytes.Contains(response.Body.Bytes(), []byte(trHashC)) {
		t.Fatalf("public manifest did not read current policy: %d %s", response.Code, response.Body.String())
	}
}

func TestReleasePolicyZeroServerRetainsSetupContracts(t *testing.T) {
	srv := &Server{logger: quietLogger()}
	if configured, hashes := srv.binaryHashPolicySnapshot(); configured || len(hashes) != 0 {
		t.Fatalf("zero server policy = %v %v", configured, hashes)
	}
	if ok, mismatches := srv.verifyRuntimeHashesForBackend("unconfigured-backend", "", "", nil); !ok || len(mismatches) != 0 {
		t.Fatalf("zero manifest = %v %v", ok, mismatches)
	}
	srv.SetKnownBinaryHashes([]string{trHashA})
	if configured, hashes := srv.binaryHashPolicySnapshot(); !configured || !hashes[trHashA] {
		t.Fatalf("zero server setup lost hash policy: %v %v", configured, hashes)
	}
	manifest := NewRuntimeManifest()
	manifest.AddTemplateHash("mlx_metallib", trHashC)
	srv.SetRuntimeManifest(manifest)
	if ok, _ := srv.verifyRuntimeHashesForBackend(registry.BackendMLXSwift, "", "", map[string]string{"mlx_metallib": trHashC}); !ok {
		t.Fatal("configured zero server rejected accepted runtime")
	}
	// Publication owns a snapshot. Later caller mutations take effect only
	// through another explicit publication, including on a zero-value server.
	manifest.AddTemplateHash("mlx_metallib", trHashD)
	if ok, _ := srv.verifyRuntimeHashesForBackend(registry.BackendMLXSwift, "", "", map[string]string{"mlx_metallib": trHashD}); ok {
		t.Fatal("caller mutation changed the published manifest")
	}
	if ok, _ := srv.verifyRuntimeHashesForBackend(registry.BackendMLXSwift, "", "", map[string]string{"mlx_metallib": trHashC}); !ok {
		t.Fatal("caller mutation discarded the published manifest")
	}
	srv.SetRuntimeManifest(manifest)
	if ok, _ := srv.verifyRuntimeHashesForBackend(registry.BackendMLXSwift, "", "", map[string]string{"mlx_metallib": trHashD}); !ok {
		t.Fatal("explicit publication did not update the manifest")
	}
	srv.SetRuntimeManifest(nil)
	if ok, mismatches := srv.verifyRuntimeHashesForBackend("unconfigured-backend", "", "", nil); !ok || len(mismatches) != 0 {
		t.Fatalf("cleared manifest = %v %v", ok, mismatches)
	}
}
