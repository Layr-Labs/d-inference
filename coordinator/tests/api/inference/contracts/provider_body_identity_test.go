package inference_test

// Byte-identity guards for the provider-bound body. The chat handler parses
// the request once, applies its rewrites to the decoded map, and serializes
// once; these tests drive real requests through httptest against a fake
// provider and compare the RAW decrypted bytes the provider receives with an
// oracle built independently (decode the original → apply the expected
// rewrite → marshalForwardBody). The request-owned date now makes every input
// a coordinator serialization, including requests with no other rewrite.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// forwardOracle decodes body, applies mutate, and serializes the way the
// handler does.
func forwardOracle(t *testing.T, body string, mutate func(map[string]any)) []byte {
	t.Helper()
	parsed, err := inreq.DecodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if mutate != nil {
		mutate(parsed)
	}
	out, err := inreq.MarshalForwardBody(parsed)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// postAndCapture posts body to path and returns the raw bytes the fake
// provider decrypted for it.
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

func assertProviderBytes(t *testing.T, got, want []byte) {
	t.Helper()
	actual, err := inreq.DecodeInferenceJSONObject(got)
	if err != nil {
		t.Fatal(err)
	}
	date, ok := actual[promptcontract.RequestDateField].(string)
	if _, err := time.Parse(time.DateOnly, date); !ok || err != nil {
		t.Fatalf("provider body has no canonical request date: %q", date)
	}
	// Clock ownership is asserted by the endpoint/fallback tests. Bind this
	// byte oracle to the observed date, leaving every other value independent.
	expected, err := inreq.DecodeInferenceJSONObject(want)
	if err != nil {
		t.Fatal(err)
	}
	expected[promptcontract.RequestDateField] = date
	want, err = inreq.MarshalForwardBody(expected)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("provider body diverged:\n got %s\nwant %s", got, want)
	}
}

// setPrefixCacheProtocol pins the fake provider's prefix-cache protocol. At
// protocol 0 every dispatch splices a per-attempt prompt_cache_key buster into
// the sealed body (see PrepareCacheAttempt); protocol 1 providers receive the
// handler's body untouched, which is what the byte-identity oracles describe.
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

// Remote media inlining mutates parsed after the first serialization; the
// provider must receive a fresh serialization of the inlined map.
func TestProviderBodyByteIdentityMediaInlined(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS", "true")
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS", "true")
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const model = "identity-media-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "identity-vision", Version: "0.7.6", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			fp.serveFull(ctx, req, model, "ok")
		},
	})
	p := reg.GetProvider(fp.registryID)
	p.Mu().Lock()
	for i := range p.Models {
		p.Models[i].IsVision = true
	}
	p.PrefixCacheProtocol = 1
	p.Mu().Unlock()

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()
	imageURL := media.URL + "/cat.png"
	body := `{"model":"` + model + `","max_tokens":16,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"describe"},{"type":"image_url","image_url":{"url":"` + imageURL + `"}}]}]}`

	got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
	if atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("origin hit %d times, want 1", hits)
	}
	// Recover the inlined data: URI from the provider body, then the oracle is
	// the original request with only that URL substituted.
	var dispatched struct {
		Messages []struct {
			Content []struct {
				Type     string `json:"type"`
				ImageURL struct {
					URL string `json:"url"`
				} `json:"image_url"`
			} `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(got, &dispatched); err != nil {
		t.Fatalf("decode provider body: %v", err)
	}
	inlined := dispatched.Messages[0].Content[1].ImageURL.URL
	if !strings.HasPrefix(inlined, "data:image/png;base64,") {
		t.Fatalf("image was not inlined: %.80s", inlined)
	}
	assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) {
		part := p["messages"].([]any)[0].(map[string]any)["content"].([]any)[1].(map[string]any)
		part["image_url"].(map[string]any)["url"] = inlined
	}))
}
