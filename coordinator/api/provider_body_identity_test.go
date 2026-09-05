package api

// Byte-identity guards for the provider-bound body. The chat handler parses
// the request once, applies its rewrites to the decoded map, and serializes
// once; these tests drive real requests through httptest against a fake
// provider and compare the RAW decrypted bytes the provider receives with an
// oracle built independently (decode the original → apply the expected
// rewrite → marshalForwardBody), or with the caller's exact input when no
// rewrite applies.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// forwardOracle decodes body, applies mutate, and serializes the way the
// handler does.
func forwardOracle(t *testing.T, body string, mutate func(map[string]any)) []byte {
	t.Helper()
	parsed, err := decodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if mutate != nil {
		mutate(parsed)
	}
	out, err := marshalForwardBody(parsed)
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

// legacyBustKey returns the protocol-0 prompt_cache_key buster a sealed body
// carries, if any.
func legacyBustKey(t *testing.T, sealed []byte) (string, bool) {
	t.Helper()
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(sealed, &fields); err != nil {
		t.Fatalf("decode sealed body: %v", err)
	}
	raw, ok := fields[legacyCacheBustField]
	if !ok {
		return "", false
	}
	var key string
	if err := json.Unmarshal(raw, &key); err != nil {
		t.Fatal(err)
	}
	return key, true
}

// assertSealedProviderBytes compares a protocol-0 provider's bytes with the
// oracle sealed the way dispatch seals it (the buster spliced at its sorted
// position), or with the bare oracle when no buster was attached.
func assertSealedProviderBytes(t *testing.T, got, oracle []byte) {
	t.Helper()
	key, ok := legacyBustKey(t, got)
	if !ok {
		assertProviderBytes(t, got, oracle)
		return
	}
	assertProviderBytes(t, got, legacySealCacheBust(t, oracle, key))
}

func createServiceKey(t *testing.T, st store.Store, account string) string {
	t.Helper()
	if err := st.CreateUser(&store.User{
		AccountID: account, PrivyUserID: "did:privy:" + account, Role: store.RoleService,
	}); err != nil {
		t.Fatal(err)
	}
	key, _, err := st.CreateAPIKey(account, store.APIKeyCreate{Name: "identity-test"})
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func TestProviderBodyByteIdentity(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	const (
		plainBuild     = "identity-plain-build"
		defaultsBuild  = "identity-defaults-build"
		alias          = "identity-alias"
		serviceAccount = "identity-service-account"
	)
	seedRuntimeDefaultsModel(t, st, defaultsBuild, map[string]any{
		"reasoning_parser": "catalog-reasoning",
		"tool_call_parser": "qwen3_coder",
	})
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "identity-provider", Version: "0.7.6", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: plainBuild}, {ID: defaultsBuild}, {ID: serviceReasoningOptInModel}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			fp.serveFull(ctx, req, plainBuild, "ok")
		},
	})
	setPrefixCacheProtocol(t, reg, fp, 1)
	reg.SetModelAliases(map[string]registry.AliasTarget{alias: {Desired: plainBuild}})
	serviceKey := createServiceKey(t, st, serviceAccount)

	messages := `[{"role":"user","content":"hello <world> & \"friends\"\n"}]`

	t.Run("verbatim passthrough", func(t *testing.T) {
		// Raw build id, explicit max_tokens, no stop string, no catalog
		// defaults, non-service key: nothing rewrites, so the caller's exact
		// bytes — unsorted keys, whitespace, escapes and all — reach the provider.
		body := "{\n  \"stream\": false,\n  \"model\": \"" + plainBuild + "\",\n  \"max_tokens\": 16,\n" +
			"  \"messages\": " + messages + ",\n  \"temperature\": 0.10000000000000001,\n  \"note\": \"\\u003c kept \\u0041\"\n}"
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, []byte(body))
	})

	t.Run("alias resolution", func(t *testing.T) {
		body := `{"model":"` + alias + `","messages":` + messages + `,"max_tokens":16}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) { p["model"] = plainBuild }))
	})

	t.Run("stop normalization", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","messages":` + messages + `,"max_tokens":16,"stop":"END"}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) { p["stop"] = []any{"END"} }))
	})

	t.Run("max_tokens bound injected", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","messages":` + messages + `}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) { p["max_tokens"] = defaultMaxOutputTokens }))
	})

	t.Run("max_completion_tokens mirrored to max_tokens", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","messages":` + messages + `,"max_completion_tokens":9}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) { p["max_tokens"] = 9 }))
	})

	t.Run("runtime defaults and catalog max_tokens", func(t *testing.T) {
		body := `{"model":"` + defaultsBuild + `","messages":` + messages + `,"tool_call_parser":"caller-parser"}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) {
			p["reasoning_parser"] = "catalog-reasoning" // injected; caller's tool_call_parser wins
			p["max_tokens"] = 8192                      // seedRuntimeDefaultsModel's MaxOutputLength
		}))
	})

	t.Run("service reasoning policy on", func(t *testing.T) {
		body := `{"model":"` + serviceReasoningOptInModel + `","messages":` + messages + `,"max_tokens":16}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", serviceKey, body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) {
			p["reasoning"] = map[string]any{"enabled": false}
		}))
	})

	t.Run("service reasoning policy off", func(t *testing.T) {
		// Same body, non-service key: no rewrite at all, verbatim passthrough.
		body := `{"model":"` + serviceReasoningOptInModel + `", "messages":` + messages + `, "max_tokens":16}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, []byte(body))
	})

	t.Run("private routing field stripped", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","messages":` + messages + `,"max_tokens":16,"provider_serial":"C02ABC","metadata_details":true}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		assertProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) {
			delete(p, "provider_serial")
			delete(p, "metadata_details")
		}))
	})

	t.Run("tools normalized", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","messages":` + messages + `,"max_tokens":16,"tool_choice":"auto",` +
			`"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"x"},"n":{"type":["integer","null"]}}}}}]}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
		// Oracle: the bytes path's normalization, then the same serialization.
		assertProviderBytes(t, got, forwardOracle(t, string(NormalizeToolSchemas([]byte(body))), nil))
	})

	t.Run("responses lowering", func(t *testing.T) {
		body := `{"model":"` + plainBuild + `","input":"hello","max_output_tokens":16}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/responses", "test-key", body)
		want, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, []byte(body))
		if err != nil {
			t.Fatal(err)
		}
		assertProviderBytes(t, got, want)
	})

	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("responses instructions stream=%t", stream), func(t *testing.T) {
			body := fmt.Sprintf(`{"model":%q,"instructions":"Answer in French.","input":"hello","max_output_tokens":16,"stream":%t}`, plainBuild, stream)
			got := postAndCapture(t, ctx, ts, fp, "/v1/responses", "test-key", body)
			want := forwardOracle(t, body, func(p map[string]any) {
				delete(p, "instructions")
				delete(p, "input")
				delete(p, "max_output_tokens")
				p["max_tokens"] = 16
				p["messages"] = []any{
					map[string]any{"role": "system", "content": "Answer in French."},
					map[string]any{"role": "user", "content": "hello"},
				}
			})
			assertProviderBytes(t, got, want)
		})
	}

	t.Run("responses lowering after rewrite", func(t *testing.T) {
		body := `{"model":"` + alias + `","input":"hello"}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/responses", "test-key", body)
		rewritten := forwardOracle(t, body, func(p map[string]any) {
			p["model"] = plainBuild
			p["max_output_tokens"] = defaultMaxOutputTokens
		})
		want, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rewritten)
		if err != nil {
			t.Fatal(err)
		}
		assertProviderBytes(t, got, want)
	})

	t.Run("protocol-0 cache isolation seal", func(t *testing.T) {
		// A protocol-0 provider receives the handler's body with the per-attempt
		// buster spliced in — through the splice fast path for the coordinator's
		// own serialization and the decode/re-encode path for a verbatim body.
		setPrefixCacheProtocol(t, reg, fp, 0)
		defer setPrefixCacheProtocol(t, reg, fp, 1)
		rewritten := `{"model":"` + alias + `","messages":` + messages + `,"max_tokens":16}`
		got := postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", rewritten)
		assertSealedProviderBytes(t, got, forwardOracle(t, rewritten, func(p map[string]any) { p["model"] = plainBuild }))

		verbatim := "{\n  \"model\": \"" + plainBuild + "\",\n  \"max_tokens\": 16,\n  \"messages\": " + messages + "\n}"
		got = postAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", verbatim)
		assertSealedProviderBytes(t, got, []byte(verbatim))
	})
}

// The alias-capacity fallback rewrites the model and reconciles the fallback
// build's runtime defaults; the provider must receive exactly that
// serialization.
func TestProviderBodyByteIdentityAliasFallback(t *testing.T) {
	previousRuntime := map[string]any{
		"reasoning_parser": "previous-reasoning",
		"tool_call_parser": "previous-tools",
	}
	harness := newRuntimeDefaultsAliasHarness(t, map[string]any{
		"reasoning_parser": "desired-reasoning",
		"tool_call_parser": "desired-tools",
	}, previousRuntime)
	body := `{"model":"` + runtimeDefaultsAlias + `","messages":[{"role":"user","content":"hello"}],"max_tokens":32,"stream":true}`
	postRuntimeDefaultsEndpoint(t, harness, "/v1/chat/completions", body)
	var got []byte
	select {
	case got = <-harness.providers[0].bodies:
	case <-time.After(5 * time.Second):
		t.Fatal("fallback provider never received the request")
	}
	// The harness's fallback provider is protocol 0, so dispatch splices the
	// buster into the fallback serialization.
	assertSealedProviderBytes(t, got, forwardOracle(t, body, func(p map[string]any) {
		p["model"] = runtimeDefaultsPreviousModel
		p["reasoning_parser"] = "previous-reasoning"
		p["tool_call_parser"] = "previous-tools"
	}))
}

// On the Responses surface the alias-capacity fallback rewrites the model and
// the fallback build's runtime defaults, then re-lowers input→chat; the
// provider must receive exactly that lowering of the rewritten map.
func TestProviderBodyByteIdentityResponsesAliasFallback(t *testing.T) {
	harness := newRuntimeDefaultsAliasHarness(t, map[string]any{
		"reasoning_parser": "desired-reasoning",
		"tool_call_parser": "desired-tools",
	}, map[string]any{
		"reasoning_parser": "previous-reasoning",
		"tool_call_parser": "previous-tools",
	})
	body := `{"model":"` + runtimeDefaultsAlias + `","input":"hello","max_output_tokens":32,"stream":true}`
	postRuntimeDefaultsEndpoint(t, harness, "/v1/responses", body)
	var got []byte
	select {
	case got = <-harness.providers[0].bodies:
	case <-time.After(5 * time.Second):
		t.Fatal("fallback provider never received the request")
	}
	rewritten := forwardOracle(t, body, func(p map[string]any) {
		p["model"] = runtimeDefaultsPreviousModel
		p["reasoning_parser"] = "previous-reasoning"
		p["tool_call_parser"] = "previous-tools"
	})
	want, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rewritten)
	if err != nil {
		t.Fatal(err)
	}
	assertSealedProviderBytes(t, got, want)
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
