package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// These assertions qualify the synthetic transport fixture, not model quality
// or hosted OpenRouter behavior. HTTP 200 alone is insufficient.
func privacyConsumerResponseError(path string, stream bool, body []byte) error {
	if !stream {
		var response map[string]any
		if err := json.Unmarshal(body, &response); err != nil {
			return err
		}
		if response["error"] != nil {
			return fmt.Errorf("consumer response contains an error")
		}
		switch path {
		case "/v1/chat/completions", "/v1/completions":
			if privacyChoiceText(response, path == "/v1/chat/completions", false) {
				return nil
			}
		case "/v1/responses":
			if response["status"] == "completed" {
				items, _ := response["output"].([]any)
				for _, raw := range items {
					item, _ := raw.(map[string]any)
					if privacyContentText(item) {
						return nil
					}
				}
			}
		case "/v1/messages":
			if response["type"] == "message" && response["stop_reason"] != nil && privacyContentText(response) {
				return nil
			}
		}
		return fmt.Errorf("consumer response lacks completed endpoint text")
	}
	text := strings.ReplaceAll(string(body), "\r\n", "\n")
	terminal, semantic := 0, false
	lastType := ""
	for _, payload := range parseSSEDataLines(text) {
		var event map[string]any
		if err := json.Unmarshal([]byte(payload), &event); err != nil {
			return fmt.Errorf("invalid SSE JSON: %w", err)
		}
		typ, _ := event["type"].(string)
		lastType = typ
		if event["error"] != nil || typ == "error" || typ == "response.failed" || typ == "response.incomplete" {
			return fmt.Errorf("consumer stream contains an error/incomplete event")
		}
		switch path {
		case "/v1/chat/completions", "/v1/completions":
			semantic = semantic || privacyChoiceText(event, path == "/v1/chat/completions", true)
		case "/v1/responses":
			if typ == "response.output_text.delta" {
				delta, _ := event["delta"].(string)
				semantic = semantic || delta != ""
			}
			if typ == "response.completed" {
				response, _ := event["response"].(map[string]any)
				if response["status"] != "completed" {
					return fmt.Errorf("Responses terminal is not completed")
				}
				terminal++
			}
		case "/v1/messages":
			if typ == "content_block_delta" {
				delta, _ := event["delta"].(map[string]any)
				value, _ := delta["text"].(string)
				semantic = semantic || value != ""
			}
			if typ == "message_stop" {
				terminal++
			}
		}
	}
	if path == "/v1/chat/completions" || path == "/v1/completions" {
		terminal = strings.Count(text, "data: [DONE]")
		if !strings.HasSuffix(strings.TrimSpace(text), "data: [DONE]") {
			return fmt.Errorf("missing final DONE")
		}
	} else if (path == "/v1/responses" && lastType != "response.completed") ||
		(path == "/v1/messages" && lastType != "message_stop") {
		return fmt.Errorf("endpoint terminal is not last")
	}
	if terminal != 1 || !semantic {
		return fmt.Errorf("consumer stream terminal=%d semantic=%t", terminal, semantic)
	}
	return nil
}

func privacyChoiceText(response map[string]any, chat, stream bool) bool {
	choices, _ := response["choices"].([]any)
	for _, raw := range choices {
		choice, _ := raw.(map[string]any)
		if !stream {
			finish, _ := choice["finish_reason"].(string)
			if finish == "" {
				continue
			}
		}
		value, _ := choice["text"].(string)
		if chat {
			field := "message"
			if stream {
				field = "delta"
			}
			message, _ := choice[field].(map[string]any)
			value, _ = message["content"].(string)
		}
		if value != "" {
			return true
		}
	}
	return false
}

func privacyContentText(response map[string]any) bool {
	items, _ := response["content"].([]any)
	for _, raw := range items {
		item, _ := raw.(map[string]any)
		text, _ := item["text"].(string)
		if text != "" {
			return true
		}
	}
	return false
}

func postPrivacyAndCapture(t *testing.T, ctx context.Context, ts *httptest.Server, fp *failoverProvider, path, apiKey, body string, inspect ...func([]byte, http.Header)) []byte {
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
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("incomplete consumer read: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("consumer status=%d", resp.StatusCode)
	}
	request, err := decodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	stream, _ := request["stream"].(bool)
	if err := privacyConsumerResponseError(path, stream, responseBody); err != nil {
		t.Fatal(err)
	}
	for _, check := range inspect {
		check(responseBody, resp.Header)
	}
	select {
	case got := <-fp.bodies:
		if got == nil {
			t.Fatal("provider could not decrypt request")
		}
		return got
	case <-time.After(5 * time.Second):
		t.Fatal("provider did not receive request")
	}
	return nil
}

func TestPrivacyConsumerResponseOracle(t *testing.T) {
	for _, fixture := range []struct {
		name, path, body string
		stream, valid    bool
	}{
		{"empty 200", "/v1/chat/completions", `{}`, false, false},
		{"wrong endpoint", "/v1/messages", `{"choices":[{"message":{"content":"ok"}}]}`, false, false},
		{"content without terminal", "/v1/chat/completions", "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n", true, false},
		{"terminal without content", "/v1/chat/completions", "data: [DONE]\n\n", true, false},
		{"duplicate terminal", "/v1/chat/completions", "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\ndata: [DONE]\n\n", true, false},
		{"chat without finish", "/v1/chat/completions", `{"choices":[{"message":{"content":"ok"}}]}`, false, false},
		{"valid chat", "/v1/chat/completions", `{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}`, false, true},
		{"valid messages", "/v1/messages", `{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}`, false, true},
		{"valid responses", "/v1/responses", `{"status":"completed","output":[{"content":[{"type":"output_text","text":"ok"}]}]}`, false, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			if valid := privacyConsumerResponseError(fixture.path, fixture.stream, []byte(fixture.body)) == nil; valid != fixture.valid {
				t.Fatalf("response oracle accepted=%t want=%t", valid, fixture.valid)
			}
		})
	}
}

func assertCallerIdentityAbsent(t *testing.T, body []byte) {
	t.Helper()
	parsed, err := decodeInferenceJSONObject(body)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"user", "metadata"} {
		if _, exists := parsed[field]; exists {
			t.Errorf("provider-bound request retains top-level caller %q", field)
		}
	}
}

// The original body remains available for the existing validation contract;
// only the prepared provider body loses the two top-level identity fields.
func TestProviderBodyPrivacyPrelude(t *testing.T) {
	srv, _, _ := newBenchServer(t)
	const body = `{"model":"privacy-model","user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"},"messages":[{"role":"user","content":"Preserve literal user and metadata in this message.","metadata":{"user":"nested-message"}}],"max_tokens":16,"temperature":0.10000000000000001,"extension":{"user":"nested-extension","metadata":{"counter":9007199254740993}},"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"user":{"type":"string"},"metadata":{"type":"object","properties":{"counter":{"type":"integer"}}}}}}}],"cache_control":{"type":"ephemeral"},"metadata_details":true}`
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewBufferString(body))
	w := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(w, r)
	if !ok {
		t.Fatalf("prelude rejected valid request: status=%d", w.Code)
	}
	if !bytes.Equal(prelude.originalRawBody, []byte(body)) {
		t.Error("original validation body changed")
	}
	got, err := prelude.body.current()
	if err != nil {
		t.Fatal(err)
	}
	assertCallerIdentityAbsent(t, got)
	want := forwardOracle(t, string(NormalizeToolSchemas([]byte(body))), func(p map[string]any) {
		delete(p, "user")
		delete(p, "metadata")
	})
	assertProviderBytes(t, got, want)
}

func TestProviderBodyPrivacyFieldShapes(t *testing.T) {
	srv, _, _ := newBenchServer(t)
	const preserved = `"model":"privacy-model","messages":[{"role":"user","content":"literal user and metadata","metadata":{"user":"nested-message"}}],"max_tokens":16,"metadata_details":true,"cache_control":{"type":"ephemeral"},"extra":{"user":"nested","metadata":{"exact":9007199254740993,"decimal":0.10000000000000001}},"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"user":{"type":"string"},"metadata":{"type":"object","properties":{"key":{"type":"string"}}}}}}}]`
	for _, fixture := range []struct{ name, fields string }{
		{"absent", ""},
		{"only user", `,"user":"synthetic-user"`},
		{"only metadata", `,"metadata":{"conversation_id":"synthetic-conversation"}`},
		{"null fields", `,"user":null,"metadata":null`},
		{"other JSON types", `,"user":9007199254740993,"metadata":["synthetic",{"id":true}]`},
		{"escaped field names", `,"u\u0073er":"synthetic-user","meta\u0064ata":{"id":"synthetic-conversation"}`},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			body := "{" + preserved + fixture.fields + "}"
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			w := httptest.NewRecorder()
			prelude, ok := srv.parseInferencePrelude(w, r)
			if !ok {
				t.Fatalf("prelude rejected input: status=%d", w.Code)
			}
			got, err := prelude.body.current()
			if err != nil {
				t.Fatal(err)
			}
			assertCallerIdentityAbsent(t, got)
			assertProviderBytes(t, got, []byte("{"+preserved+"}"))
			if !bytes.Equal(prelude.originalRawBody, []byte(body)) {
				t.Error("original validation bytes changed")
			}
			// Reprocessing an already prepared body is idempotent; date ownership
			// is compared under the existing canonical-date oracle.
			again, ok := srv.parseInferencePrelude(httptest.NewRecorder(),
				httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(got)))
			if !ok {
				t.Fatal("prepared body was rejected")
			}
			repeated, err := again.body.current()
			if err != nil {
				t.Fatal(err)
			}
			assertProviderBytes(t, repeated, got)
		})
	}
}

func TestProviderBodyPrivacyPreparedCacheControls(t *testing.T) {
	reg, provider, pending := preparedCacheAttemptForTest(t)
	srv, _, _ := newBenchServer(t)
	const body = `{"model":"model","messages":[{"role":"user","content":"hello"}],"user":"not-the-authenticated-account","metadata":{"conversation_id":"synthetic"},"cache_control":{"type":"ephemeral"},"max_tokens":16}`
	prelude, ok := srv.parseInferencePrelude(httptest.NewRecorder(),
		httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)))
	if !ok {
		t.Fatal("prelude failed")
	}
	prepared, err := prelude.body.current()
	if err != nil {
		t.Fatal(err)
	}
	sealedBody, err := bodyForCacheAttempt(prepared, false, provider, pending)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(prepared, sealedBody) {
		t.Error("v2 attempt changed the sanitized inference body")
	}
	assertCallerIdentityAbsent(t, sealedBody)
	wire := providerInferenceWireMessage("request", "synthetic-sender", "synthetic-ciphertext", pending)
	if wire.CacheScope != pending.CachePlan.CacheScope || wire.CacheScope == "" ||
		wire.CacheReceiptNonce == "" || wire.PrefixCacheProtocol != 2 ||
		wire.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
		t.Fatal("prepared authenticated cache controls changed")
	}
	builder := providerInferenceFrameBuilder("request", "synthetic-sender", "synthetic-ciphertext", pending)
	reg.ForgetCacheAttempt(pending)
	encoded, err := builder(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var revoked protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &revoked); err != nil {
		t.Fatal(err)
	}
	if revoked.CacheScope != "" || revoked.CacheReceiptNonce != "" || revoked.PrefixCacheProtocol != 0 {
		t.Fatal("revoked cache controls survived on a prepared frame")
	}
	if revoked.EncryptedBody == nil || revoked.EncryptedBody.Ciphertext != "synthetic-ciphertext" {
		t.Fatal("cache revocation changed ordinary inference envelope")
	}
}

func TestProviderBodyPrivacyCandidateBodyParity(t *testing.T) {
	srv, _, _ := newBenchServer(t)
	registerBuildsProvider(srv, "privacy-memo", benchDesiredBuild, benchPreviousBuild)
	for _, fields := range []string{
		`"messages":[{"role":"user","content":"hello"}],"max_tokens":16`,
		`"input":"hello","max_output_tokens":16`,
	} {
		body := fmt.Sprintf(`{"model":%q,%s,"user":"synthetic","metadata":{"conversation_id":"synthetic"}}`, benchAlias, fields)
		providerBody, parsed, defaults, model, reasoning, responses, _ := runChatRewrites(t, srv, body, false)
		fresh, err := srv.candidateProviderBody(parsed, defaults, model, false, reasoning, responses)
		if err != nil {
			t.Fatal(err)
		}
		assertCallerIdentityAbsent(t, fresh)
		if !bytes.Equal(providerBody, fresh) {
			t.Fatal("handler and candidate/planning preparation differ")
		}
	}
}
