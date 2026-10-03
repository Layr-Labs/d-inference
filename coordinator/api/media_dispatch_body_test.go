package api

// Regression tests for the two contracts that bind remote-media inlining to the
// rest of the request lifecycle: the body actually handed to a provider, and the
// balance reservation held while that body is in flight. Both were previously
// unpinned — every media test asserted only that the origin was hit and that the
// response was not a media-gate 4xx, which a request that fetched the image and
// then dispatched the original URL passes.

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestChatCompletionsDispatchesInlinedMediaBody is the end-to-end contract: what
// the PROVIDER receives must be the inlined data: URI, never the http(s) URL the
// consumer sent. The coordinator is the only component allowed to fetch, so a
// dispatched URL means the fetch was paid for and thrown away and the provider's
// data:-only guard will reject the request — the exact failure this feature
// exists to remove.
func TestChatCompletionsDispatchesInlinedMediaBody(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS", "true")
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS", "true")

	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const model = "media-inline-dispatch-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name:      "vision-inline",
		Version:   "0.7.6",
		DecodeTPS: 200,
		Models:    []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			fp.serveFull(ctx, req, model, "ok")
		},
	})
	p := reg.GetProvider(fp.registryID)
	if p == nil {
		t.Fatal("provider missing from registry after registration")
	}
	p.Mu().Lock()
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
		}
	}
	p.Mu().Unlock()

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()
	imageURL := media.URL + "/cat.png"

	body := `{"model":"` + model + `","max_tokens":16,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"describe"},` +
		`{"type":"image_url","image_url":{"url":"` + imageURL + `"}}]}]}`

	status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
	if err != nil {
		t.Fatalf("postChat: %v", err)
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("origin hit %d time(s), want exactly 1; status=%d body=%.200s", n, status, respBody)
	}

	select {
	case got := <-fp.bodies:
		if got == nil {
			t.Fatal("provider could not decrypt the dispatched body")
		}
		if s := string(got); !strings.Contains(s, "data:image/png;base64,") {
			t.Errorf("dispatched body carries no inlined data: URI:\n%.400s", s)
		} else if strings.Contains(s, imageURL) {
			t.Errorf("dispatched body still carries the remote URL %q:\n%.400s", imageURL, s)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("provider never received an inference request (status=%d body=%.300s)", status, respBody)
	}
}
