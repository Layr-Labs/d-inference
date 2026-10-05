package inference_test

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// These provider-body capture and SSE helpers match the contracts package's
// fixtures of the same names; the cache-planning HTTP cases here use them.
func postAndCapture(t *testing.T, ctx context.Context, ts *httptest.Server, fp *failoverProvider, path, apiKey, body string) []byte {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	respBody := new(bytes.Buffer)
	respBody.ReadFrom(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", resp.StatusCode, respBody.String())
	}
	select {
	case got := <-fp.bodies:
		if got == nil {
			t.Fatal("provider could not decrypt the dispatched body")
		}
		return got
	case <-time.After(10 * time.Second):
		t.Fatal("provider never received the request")
	}
	return nil
}

func setPrefixCacheProtocol(t *testing.T, reg *registry.Registry, fp *failoverProvider, protocol int) {
	t.Helper()
	p := reg.GetProvider(fp.registryID)
	if p == nil {
		t.Fatal("provider missing from registry")
	}
	p.Mu().Lock()
	p.PrefixCacheProtocol = protocol
	p.Mu().Unlock()
}

func parseSSEDataLines(body string) []string {
	var events []string
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "[DONE]" || payload == "" {
			continue
		}
		events = append(events, payload)
	}
	return events
}
