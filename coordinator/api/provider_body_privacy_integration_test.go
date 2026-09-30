package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/nacl/box"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderBodyPrivacySenderSealed(t *testing.T) {
	for _, endpoint := range privacyLifecycleEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				reg, _, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				key, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
				if err != nil {
					t.Fatal(err)
				}
				srv.SetCoordinatorKey(key)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const model = "privacy-sealed"
				fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "privacy-sealed-provider", Version: "0.8.10", DecodeTPS: 100,
					Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
				})
				setPrefixCacheProtocol(t, reg, fp, 1)
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"}}`, model, endpoint.fields, stream)
				body = strings.ReplaceAll(body, "hello", fmt.Sprintf("sealed-%s-%t", endpoint.name, stream))
				envelope, _, senderKey := sealRequest(t, []byte(body), key.PublicKey, key.KID)
				r, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+endpoint.path, bytes.NewReader(envelope))
				if err != nil {
					t.Fatal(err)
				}
				r.Header.Set("Authorization", "Bearer test-key")
				r.Header.Set("Content-Type", SealedContentType)
				response, err := http.DefaultClient.Do(r)
				if err != nil {
					t.Fatal(err)
				}
				defer response.Body.Close()
				wire, err := io.ReadAll(response.Body)
				if err != nil {
					t.Fatal(err)
				}
				if response.StatusCode != http.StatusOK || response.Header.Get("X-Eigen-Sealed") != "true" {
					t.Fatalf("sealed response status=%d sealed=%q", response.StatusCode, response.Header.Get("X-Eigen-Sealed"))
				}
				var plaintext []byte
				if stream {
					for _, frame := range bytes.Split(bytes.TrimSpace(wire), []byte("\n\n")) {
						if !bytes.HasPrefix(frame, []byte("data: ")) {
							t.Fatal("sealed stream contains a plaintext/non-data frame")
						}
						ciphertext, err := base64.StdEncoding.DecodeString(string(bytes.TrimPrefix(frame, []byte("data: "))))
						if err != nil || len(ciphertext) < 24 {
							t.Fatal("invalid sealed stream envelope")
						}
						var nonce [24]byte
						copy(nonce[:], ciphertext[:24])
						decoded, ok := box.Open(nil, ciphertext[24:], &nonce, &key.PublicKey, senderKey)
						if !ok {
							t.Fatal("consumer stream authentication failed")
						}
						plaintext = append(plaintext, decoded...)
						plaintext = append(plaintext, '\n', '\n')
					}
				} else {
					if !strings.HasPrefix(response.Header.Get("Content-Type"), SealedContentType) {
						t.Fatal("consumer response was not sealed")
					}
					plaintext = unsealResponse(t, wire, key.PublicKey, senderKey)
				}
				if err := privacyConsumerResponseError(endpoint.path, stream, plaintext); err != nil {
					t.Fatal(err)
				}
				select {
				case got := <-fp.bodies:
					assertCallerIdentityAbsent(t, got)
					assertProviderBytes(t, got, privacyLifecycleOracle(t, body, endpoint.kind))
				case <-ctx.Done():
					t.Fatal("provider did not decrypt sealed ingress request")
				}
				if fp.dispatchCount() != 1 || len(fp.bodies) != 0 {
					t.Error("sealed request did not dispatch exactly once")
				}
			})
		}
	}
}

var privacyLifecycleEndpoints = []struct {
	name, path, fields string
	kind               promptcontract.Endpoint
}{
	{"chat", "/v1/chat/completions", `"messages":[{"role":"user","content":"hello"}],"max_tokens":64`, promptcontract.EndpointChatCompletions},
	{"responses", "/v1/responses", `"input":"hello","max_output_tokens":64`, promptcontract.EndpointResponses},
	{"completions", "/v1/completions", `"prompt":"hello","max_tokens":64`, promptcontract.EndpointCompletions},
	{"messages", "/v1/messages", `"messages":[{"role":"user","content":"hello"}],"max_tokens":64`, promptcontract.EndpointMessages},
}

func privacyLifecycleOracle(t *testing.T, body string, endpoint promptcontract.Endpoint) []byte {
	t.Helper()
	want := forwardOracle(t, body, func(p map[string]any) {
		delete(p, "user")
		delete(p, "metadata")
	})
	if endpoint == promptcontract.EndpointChatCompletions {
		return want
	}
	want, err := promptcontract.LowerProviderBody(endpoint, want)
	if err != nil {
		t.Fatal(err)
	}
	return want
}

func TestProviderBodyPrivacyRetryEncrypted(t *testing.T) {
	for _, endpoint := range privacyLifecycleEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				reg, _, ts := setupFailoverServer(t)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const model = "privacy-retry"
				recorder := &dispatchRecorder{}
				script := failFirstScript(recorder, model, "error")
				first := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "privacy-retry-a", Version: "0.7.6", DecodeTPS: 200,
					Models: []failoverModelSpec{{ID: model}}, Script: script,
				})
				second := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "privacy-retry-b", Version: "0.7.6", DecodeTPS: 1,
					Models: []failoverModelSpec{{ID: model}}, Script: script,
				})
				setPrefixCacheProtocol(t, reg, first, 0)
				setPrefixCacheProtocol(t, reg, second, 0)
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"}}`, model, endpoint.fields, stream)
				body = strings.ReplaceAll(body, "hello", fmt.Sprintf("privacy-%s-%t", endpoint.name, stream))
				firstBody := postPrivacyAndCapture(t, ctx, ts, first, endpoint.path, "test-key", body)
				var secondBody []byte
				select {
				case secondBody = <-second.bodies:
				case <-ctx.Done():
					t.Fatal("second provider did not receive the retry")
				}
				sequence := recorder.sequence()
				if len(sequence) != 2 || sequence[0] == sequence[1] || first.dispatchCount()+second.dispatchCount() != 2 {
					t.Fatalf("expected one failed primary and one distinct retry: %v", sequence)
				}
				// Check both attempts and independent isolation controls before a
				// byte-oracle failure can terminate this subtest.
				for _, got := range [][]byte{firstBody, secondBody} {
					assertCallerIdentityAbsent(t, got)
				}
				firstKey, firstHasKey := legacyBustKey(t, firstBody)
				secondKey, secondHasKey := legacyBustKey(t, secondBody)
				if !firstHasKey || !secondHasKey || firstKey == "" || secondKey == "" || firstKey == secondKey {
					t.Error("per-attempt legacy cache isolation keys were absent or reused")
				}
				want := privacyLifecycleOracle(t, body, endpoint.kind)
				for _, got := range [][]byte{firstBody, secondBody} {
					assertSealedProviderBytes(t, got, want)
				}
			})
		}
	}
}

func TestProviderBodyPrivacyQueuedEncrypted(t *testing.T) {
	// Match existing queue fixtures: these controls select the queueing path,
	// not a change to shipping admission or any cache security policy.
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")
	for _, endpoint := range privacyLifecycleEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				reg, _, ts := setupFailoverServer(t)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const model = "privacy-queued"
				reg.SetDedicatedModels([]string{model})
				fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: "privacy-queue-provider", Version: "0.8.10", DecodeTPS: 100,
					Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
				})
				setPrefixCacheProtocol(t, reg, fp, 0)
				p := reg.GetProvider(fp.registryID)
				capacity := func(used int64) {
					writeAdaptiveHeartbeat(t, ctx, fp.conn, model, &protocol.BackendCapacity{
						TotalMemoryGB: 64,
						Slots: []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 8,
							ActiveTokenBudgetUsed: used, ActiveTokenBudgetMax: 1000}},
					})
				}
				capacity(950)
				waitForAdaptiveCondition(t, time.Second, func() bool {
					p.Mu().Lock()
					defer p.Mu().Unlock()
					return p.BackendCapacity != nil && len(p.BackendCapacity.Slots) == 1 &&
						p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
				})
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"}}`, model, endpoint.fields, stream)
				body = strings.ReplaceAll(body, "hello", fmt.Sprintf("privacy-%s-%t", endpoint.name, stream))
				type result struct {
					status int
					err    error
					body   []byte
				}
				done := make(chan result, 1)
				go func() {
					r, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+endpoint.path, strings.NewReader(body))
					if err != nil {
						done <- result{err: err}
						return
					}
					r.Header.Set("Authorization", "Bearer test-key")
					r.Header.Set("Content-Type", "application/json")
					r.Header.Set("X-Darkbloom-Route", "prefer")
					response, err := http.DefaultClient.Do(r)
					if err != nil {
						done <- result{err: err}
						return
					}
					responseBody, readErr := io.ReadAll(response.Body)
					response.Body.Close()
					done <- result{status: response.StatusCode, err: readErr, body: responseBody}
				}()
				waitForAdaptiveCondition(t, 3*time.Second, func() bool { return reg.Queue().QueueSize(model) == 1 })
				if fp.dispatchCount() != 0 {
					t.Fatal("request dispatched before queued capacity was freed")
				}
				capacity(0)
				select {
				case response := <-done:
					if response.err != nil || response.status != http.StatusOK {
						t.Fatalf("queued request: status=%d error=%v", response.status, response.err)
					}
					if err := privacyConsumerResponseError(endpoint.path, stream, response.body); err != nil {
						t.Fatal(err)
					}
				case <-ctx.Done():
					t.Fatal("queued request did not complete")
				}
				var got []byte
				select {
				case got = <-fp.bodies:
				case <-ctx.Done():
					t.Fatal("provider did not decrypt queued request")
				}
				if fp.dispatchCount() != 1 || reg.Queue().QueueSize(model) != 0 {
					t.Error("queued request did not drain exactly once")
				}
				assertCallerIdentityAbsent(t, got)
				assertSealedProviderBytes(t, got, privacyLifecycleOracle(t, body, endpoint.kind))
			})
		}
	}
}

// Drive the actual HTTP handlers and inspect the fake provider's decrypted
// request. These are transport/privacy fixtures, not real model inference.
func TestProviderBodyPrivacyDirectEncrypted(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	const model = "privacy-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "privacy-provider", Version: "0.7.6", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			fp.serveFull(ctx, req, model, "ok")
		},
	})
	setPrefixCacheProtocol(t, reg, fp, 1)
	for _, endpoint := range []struct {
		name, path, fields string
		kind               promptcontract.Endpoint
	}{
		{"chat", "/v1/chat/completions", `"messages":[{"role":"user","content":"hello"}],"max_tokens":16`, promptcontract.EndpointChatCompletions},
		{"responses", "/v1/responses", `"input":"hello","max_output_tokens":16`, promptcontract.EndpointResponses},
		{"completions", "/v1/completions", `"prompt":"hello","max_tokens":16`, promptcontract.EndpointCompletions},
		{"messages", "/v1/messages", `"messages":[{"role":"user","content":"hello"}],"max_tokens":16`, promptcontract.EndpointMessages},
	} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t,"user":"synthetic-customer","metadata":{"app":"synthetic-app","conversation_id":"synthetic-ticket"},"temperature":0.10000000000000001}`, model, endpoint.fields, stream)
				body = strings.ReplaceAll(body, "hello", fmt.Sprintf("privacy-%s-%t", endpoint.name, stream))
				before := fp.dispatchCount()
				got := postPrivacyAndCapture(t, ctx, ts, fp, endpoint.path, "test-key", body)
				if fp.dispatchCount() != before+1 || len(fp.bodies) != 0 {
					t.Error("direct request did not dispatch exactly once")
				}
				assertCallerIdentityAbsent(t, got)
				want := forwardOracle(t, body, func(p map[string]any) {
					delete(p, "user")
					delete(p, "metadata")
				})
				if endpoint.kind != promptcontract.EndpointChatCompletions {
					var err error
					want, err = promptcontract.LowerProviderBody(endpoint.kind, want)
					if err != nil {
						t.Fatal(err)
					}
				}
				assertProviderBytes(t, got, want)
			})
		}
	}
}

func TestProviderBodyPrivacyAliasFallback(t *testing.T) {
	for _, endpoint := range privacyLifecycleEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				harness := newRuntimeDefaultsAliasHarness(t,
					map[string]any{"reasoning_parser": "desired-reasoning", "tool_call_parser": "desired-tools"},
					map[string]any{"reasoning_parser": "previous-reasoning", "tool_call_parser": "previous-tools"})
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"}}`, runtimeDefaultsAlias, endpoint.fields, stream)
				got := postPrivacyAndCapture(t, harness.ctx, harness.server, harness.providers[0], endpoint.path, "test-key", body)
				assertCallerIdentityAbsent(t, got)
				want := forwardOracle(t, body, func(p map[string]any) {
					delete(p, "user")
					delete(p, "metadata")
					p["model"] = runtimeDefaultsPreviousModel
					p["reasoning_parser"] = "previous-reasoning"
					p["tool_call_parser"] = "previous-tools"
				})
				if endpoint.kind != promptcontract.EndpointChatCompletions {
					var err error
					want, err = promptcontract.LowerProviderBody(endpoint.kind, want)
					if err != nil {
						t.Fatal(err)
					}
				}
				assertSealedProviderBytes(t, got, want)
			})
		}
	}
}

func TestProviderBodyPrivacyMediaReplacement(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS", "true")
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS", "true")
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "privacy-media"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "privacy-media-provider", Version: "0.7.6", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
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
	body := fmt.Sprintf(`{"model":%q,"max_tokens":16,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"},"messages":[{"role":"user","content":[{"type":"text","text":"describe"},{"type":"image_url","image_url":{"url":%q}}]}]}`, model, media.URL+"/fixture.png")
	got := postPrivacyAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body)
	assertCallerIdentityAbsent(t, got)
	if atomic.LoadInt32(&hits) != 1 {
		t.Fatalf("media fetched %d times", atomic.LoadInt32(&hits))
	}
	var decoded struct {
		Messages []struct {
			Content []struct {
				ImageURL struct {
					URL string `json:"url"`
				} `json:"image_url"`
			} `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(got, &decoded); err != nil || len(decoded.Messages) != 1 || len(decoded.Messages[0].Content) != 2 {
		t.Fatal("media content shape changed")
	}
	url := "data:image/png;base64," + base64.StdEncoding.EncodeToString(testPNG(t))
	if decoded.Messages[0].Content[1].ImageURL.URL != url {
		t.Fatal("media replacement did not preserve the independent PNG fixture bytes")
	}
	want := forwardOracle(t, body, func(p map[string]any) {
		delete(p, "user")
		delete(p, "metadata")
		part := p["messages"].([]any)[0].(map[string]any)["content"].([]any)[1].(map[string]any)
		part["image_url"].(map[string]any)["url"] = url
	})
	assertProviderBytes(t, got, want)
}

func TestProviderBodyPrivacyGenericNativeForwardFallback(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "privacy-native-forward"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "privacy-native-forward-provider", Version: "0.7.6", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	setPrefixCacheProtocol(t, reg, fp, 1)
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%t", stream), func(t *testing.T) {
			body := fmt.Sprintf(`{"model":%q,"prompt":["first","second"],"max_tokens":16,"stream":%t,"user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"}}`, model, stream)
			if _, err := promptcontract.LowerProviderBody(promptcontract.EndpointCompletions, []byte(body)); err != promptcontract.ErrEndpointBodyUnsupported {
				t.Fatalf("fixture does not exercise native-forward fallback: %v", err)
			}
			got := postPrivacyAndCapture(t, ctx, ts, fp, "/v1/completions", "test-key", body)
			assertCallerIdentityAbsent(t, got)
			want := forwardOracle(t, body, func(p map[string]any) {
				delete(p, "user")
				delete(p, "metadata")
				// The existing native-forward path retains its endpoint marker.
				p["endpoint"] = "/v1/completions"
			})
			assertProviderBytes(t, got, want)
		})
	}
}

func TestProviderBodyPrivacyRetainsMetadataDetails(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "privacy-metadata-details"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "privacy-metadata-provider", Version: "0.7.6", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	setPrefixCacheProtocol(t, reg, fp, 1)
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%t", stream), func(t *testing.T) {
			body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"max_tokens":16,"stream":%t,"metadata_details":true,"user":"synthetic-customer","metadata":{"caller_marker":"must-not-forward"}}`, model, stream)
			got := postPrivacyAndCapture(t, ctx, ts, fp, "/v1/chat/completions", "test-key", body, func(response []byte, headers http.Header) {
				payloads := []string{string(response)}
				if stream {
					payloads = parseSSEDataLines(string(response))
				}
				found := 0
				for _, payload := range payloads {
					var frame map[string]any
					if err := json.Unmarshal([]byte(payload), &frame); err != nil {
						t.Fatal(err)
					}
					if metadata, ok := frame["metadata"].(map[string]any); ok {
						found++
						providerID, _ := metadata["provider_id"].(string)
						if providerID == "" || providerID != headers.Get("X-Provider-Id") || metadata["timing"] == nil {
							t.Error("coordinator metadata details or header pairing changed")
						}
						if _, leaked := metadata["caller_marker"]; leaked {
							t.Error("caller metadata became response metadata")
						}
					}
				}
				if found != 1 {
					t.Errorf("coordinator metadata count=%d want1", found)
				}
			})
			assertCallerIdentityAbsent(t, got)
			want := forwardOracle(t, body, func(p map[string]any) {
				delete(p, "user")
				delete(p, "metadata")
				delete(p, "metadata_details")
			})
			assertProviderBytes(t, got, want)
		})
	}
}
