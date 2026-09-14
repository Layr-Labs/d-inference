package api

import (
	"bytes"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestReleaseEndpointsUseCurrentStoreAndCache(t *testing.T) {
	srv, initial := testServer(t)
	defer srv.Close()
	setReleaseForCacheTest(t, initial, "1.0.0", defaultReleasePlatform, "initial")
	srv.SetRuntimeManifest(&RuntimeManifest{TemplateHashes: map[string]map[string]bool{"mlx_metallib": {trHashC: true}}})
	for _, path := range []string{"/v1/releases/latest", "/v1/runtime/manifest"} {
		if response := doReq(srv, http.MethodGet, path, "", ""); response.Code != http.StatusOK {
			t.Fatalf("prime %s: %d %s", path, response.Code, response.Body.String())
		}
	}
	current := store.NewMemory(store.Config{})
	setReleaseForCacheTest(t, current, "1.1.0", defaultReleasePlatform, "current")
	srv.store = current
	srv.readCache = newTTLCache()
	srv.adminKey = "current-admin"
	srv.SetRuntimeManifest(&RuntimeManifest{TemplateHashes: map[string]map[string]bool{"mlx_metallib": {trHashD: true}}})
	latest := doReq(srv, http.MethodGet, "/v1/releases/latest", "", "")
	if latest.Code != http.StatusOK || !bytes.Contains(latest.Body.Bytes(), []byte(`"version":"1.1.0"`)) {
		t.Fatalf("current latest: %d %s", latest.Code, latest.Body.String())
	}
	manifest := doReq(srv, http.MethodGet, "/v1/runtime/manifest", "", "")
	if manifest.Code != http.StatusOK || !bytes.Contains(manifest.Body.Bytes(), []byte(trHashD)) || bytes.Contains(manifest.Body.Bytes(), []byte(trHashC)) {
		t.Fatalf("current manifest: %d %s", manifest.Code, manifest.Body.String())
	}
	list := doReq(srv, http.MethodGet, "/v1/admin/releases", "Bearer current-admin", "")
	if list.Code != http.StatusOK || !bytes.Contains(list.Body.Bytes(), []byte(`"version":"1.1.0"`)) {
		t.Fatalf("current inventory: %d %s", list.Code, list.Body.String())
	}
	refused := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer wrong", `{"version":"1.1.0","force":true}`)
	if refused.Code != http.StatusForbidden || current.GetLatestRelease(defaultReleasePlatform) == nil {
		t.Fatalf("unauthorized mutation: %d %s", refused.Code, refused.Body.String())
	}
	deleted := doReq(srv, http.MethodDelete, "/v1/admin/releases", "Bearer current-admin", `{"version":"1.1.0","force":true}`)
	if deleted.Code != http.StatusOK || current.GetLatestRelease(defaultReleasePlatform) != nil {
		t.Fatalf("current deactivation: %d %s", deleted.Code, deleted.Body.String())
	}
	if initial.GetLatestRelease(defaultReleasePlatform) == nil {
		t.Fatal("deactivation changed detached initial store")
	}
	latest = doReq(srv, http.MethodGet, "/v1/releases/latest", "", "")
	if latest.Code != http.StatusNotFound {
		t.Fatalf("current cache not invalidated after mutation: %d %s", latest.Code, latest.Body.String())
	}
}
