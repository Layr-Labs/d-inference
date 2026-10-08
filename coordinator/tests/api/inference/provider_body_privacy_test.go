package inference_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// forwardOracle decodes body, applies mutate, and serializes the way the
// handler does. It and assertProviderBytes are this package's copies of the
// byte oracle in contracts/provider_body_identity_test.go.
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

func assertCallerIdentityAbsent(t *testing.T, body []byte) {
	t.Helper()
	parsed, err := inreq.DecodeInferenceJSONObject(body)
	if err != nil {
		t.Fatal(err)
	}
	// Protocol-0 may append its coordinator-authored cache-bust key after
	// sanitization. Exact body oracles distinguish it from caller input.
	if parsed["prompt_cache_key"] == "synthetic-caller-key" {
		t.Error("caller cache key forwarded")
	}
	for _, field := range []string{"user", "metadata", "safety_identifier"} {
		if _, exists := parsed[field]; exists {
			t.Errorf("provider-bound request retains top-level caller %q", field)
		}
	}
}

// The original body remains available for the existing validation contract;
// only the prepared provider body loses the top-level identity and cache-routing fields.
func TestProviderBodyPrivacyPrelude(t *testing.T) {
	srv, _ := testServer(t)
	const body = `{"model":"privacy-model","user":"synthetic-customer","metadata":{"conversation_id":"synthetic-ticket"},"messages":[{"role":"user","content":"Preserve literal user and metadata in this message.","metadata":{"user":"nested-message"}}],"max_tokens":16,"temperature":0.10000000000000001,"extension":{"user":"nested-extension","metadata":{"counter":9007199254740993}},"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"user":{"type":"string"},"metadata":{"type":"object","properties":{"counter":{"type":"integer"}}}}}}}],"cache_control":{"type":"ephemeral"},"metadata_details":true}`
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewBufferString(body))
	w := httptest.NewRecorder()
	prelude, ok := srv.NewPreludeParser().Parse(w, r)
	if !ok {
		t.Fatalf("prelude rejected valid request: status=%d", w.Code)
	}
	if !bytes.Equal(prelude.OriginalRawBody, []byte(body)) {
		t.Error("original validation body changed")
	}
	got, err := prelude.Body.Current()
	if err != nil {
		t.Fatal(err)
	}
	assertCallerIdentityAbsent(t, got)
	want := forwardOracle(t, string(inreq.NormalizeToolSchemas([]byte(body))), func(p map[string]any) {
		delete(p, "user")
		delete(p, "metadata")
	})
	assertProviderBytes(t, got, want)
}

func TestProviderBodyPrivacyFieldShapes(t *testing.T) {
	srv, _ := testServer(t)
	const preserved = `"model":"privacy-model","messages":[{"role":"user","content":"literal user and metadata","metadata":{"user":"nested-message"}}],"max_tokens":16,"metadata_details":true,"cache_control":{"type":"ephemeral"},"extra":{"user":"nested","metadata":{"exact":9007199254740993,"decimal":0.10000000000000001}},"tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"user":{"type":"string"},"metadata":{"type":"object","properties":{"key":{"type":"string"}}}}}}}]`
	for _, fixture := range []struct{ name, fields string }{
		{"absent", ""},
		{"cache key", `,"prompt_cache_key":"caller-cache-key"`},
		{"safety identifier", `,"safety_identifier":"caller-safety-id"`},
		{"escaped new keys", `,"prompt_cache_\u006bey":"caller-cache-key","safety_\u0069dentifier":"caller-safety-id"`},
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
			prelude, ok := srv.NewPreludeParser().Parse(w, r)
			if !ok {
				t.Fatalf("prelude rejected input: status=%d", w.Code)
			}
			got, err := prelude.Body.Current()
			if err != nil {
				t.Fatal(err)
			}
			assertCallerIdentityAbsent(t, got)
			assertProviderBytes(t, got, []byte("{"+preserved+"}"))
			if !bytes.Equal(prelude.OriginalRawBody, []byte(body)) {
				t.Error("original validation bytes changed")
			}
			// Reprocessing an already prepared body is idempotent; date ownership
			// is compared under the existing canonical-date oracle.
			again, ok := srv.NewPreludeParser().Parse(httptest.NewRecorder(),
				httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(got)))
			if !ok {
				t.Fatal("prepared body was rejected")
			}
			repeated, err := again.Body.Current()
			if err != nil {
				t.Fatal(err)
			}
			assertProviderBytes(t, repeated, got)
		})
	}
}

func TestProviderBodyPrivacyPreparedCacheControls(t *testing.T) {
	reg, _, pending := preparedCacheAttemptForTest(t)
	srv, _ := testServer(t)
	const body = `{"model":"model","messages":[{"role":"user","content":"hello"}],"user":"not-the-authenticated-account","metadata":{"conversation_id":"synthetic"},"cache_control":{"type":"ephemeral"},"max_tokens":16}`
	prelude, ok := srv.NewPreludeParser().Parse(httptest.NewRecorder(),
		httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body)))
	if !ok {
		t.Fatal("prelude failed")
	}
	prepared, err := prelude.Body.Current()
	if err != nil {
		t.Fatal(err)
	}
	sealedBody, err := providerwire.BodyForCacheAttempt(prepared, pending.LegacyCacheBustKey)
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
	builder := providerwire.FrameBuilder("request", "synthetic-sender", "synthetic-ciphertext", pending)
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
