package api_test

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
)

type releaseArtifactSet struct {
	mu      sync.RWMutex
	bundles map[string][]byte
}

func (s *releaseArtifactSet) handler(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	bundle := append([]byte(nil), s.bundles[r.URL.Path]...)
	s.mu.RUnlock()
	if len(bundle) == 0 {
		http.NotFound(w, r)
		return
	}
	_, _ = w.Write(bundle)
}

func deactivateReleaseForCacheTest(t *testing.T, baseURL, version, platform string) {
	t.Helper()
	body := fmt.Sprintf(`{"version":%q,"platform":%q,"force":true}`, version, platform)
	req, err := http.NewRequest(http.MethodDelete, baseURL+"/v1/admin/releases", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer admin-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("deactivate %s/%s: status=%d body=%s", version, platform, resp.StatusCode, responseBody)
	}
}

func getReleaseBody(t *testing.T, endpoint string, wantStatus int) []byte {
	t.Helper()
	resp, err := http.Get(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != wantStatus {
		t.Fatalf("GET %s: status=%d want=%d body=%s", endpoint, resp.StatusCode, wantStatus, body)
	}
	return body
}
