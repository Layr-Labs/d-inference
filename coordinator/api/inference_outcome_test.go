package api

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestOpenRouterCredentialClassifierUsesExactCredential(t *testing.T) {
	token := "high-entropy-openrouter-token"
	sum := sha256.Sum256([]byte(token))
	classifier := newOpenRouterCredentialClassifier(
		[]string{"key_openrouter"}, []string{hex.EncodeToString(sum[:])}, nil)

	if !classifier.matchesToken(token) {
		t.Fatal("configured credential fingerprint did not match")
	}
	if classifier.matchesToken(token + "-other") {
		t.Fatal("different credential matched")
	}
	if !classifier.matchesKeyID("key_openrouter") {
		t.Fatal("configured key id did not match")
	}
	if classifier.matchesKeyID("key_other") {
		t.Fatal("different key id matched")
	}
}

func TestOpenRouterCredentialClassifierRejectsMalformedFingerprint(t *testing.T) {
	classifier := newOpenRouterCredentialClassifier(nil, []string{"not-a-sha256"}, nil)
	if classifier.matchesToken("anything") {
		t.Fatal("malformed fingerprint was accepted")
	}
}

func TestClassifyRequestTerminalStatus(t *testing.T) {
	tests := map[int]string{
		http.StatusOK:                    requestClassSuccess,
		http.StatusBadRequest:            requestClassExcluded400,
		http.StatusUnauthorized:          requestClassIntegrationError,
		http.StatusPaymentRequired:       requestClassIntegrationError,
		http.StatusForbidden:             requestClassExcluded403,
		http.StatusNotFound:              requestClassIntegrationError,
		http.StatusRequestEntityTooLarge: requestClassExcluded413,
		http.StatusTooManyRequests:       requestClassExcluded429,
		http.StatusRequestTimeout:        requestClassTimeout,
		http.StatusInternalServerError:   requestClassProvider5xx,
		http.StatusGatewayTimeout:        requestClassTimeout,
		0:                                requestClassProvider5xx,
	}
	for status, want := range tests {
		if got := classifyRequestTerminalStatus(status); got != want {
			t.Errorf("status %d classified %q, want %q", status, got, want)
		}
	}
}

func TestInferenceOutcomeExplicitInBandFailureOverridesHTTP200(t *testing.T) {
	state := &inferenceOutcomeState{exact: true, endpoint: "/v1/responses"}
	state.mark("model-a", requestClassSuccess)
	state.mark("", requestClassMidStream)

	exact, model, class, endpoint := state.snapshot(http.StatusOK)
	if !exact || model != "model-a" || class != requestClassMidStream || endpoint != "/v1/responses" {
		t.Fatalf("snapshot = (%v, %q, %q, %q)", exact, model, class, endpoint)
	}
}

func TestInferenceOutcomeHTTPErrorOverridesCommitApproximation(t *testing.T) {
	state := &inferenceOutcomeState{exact: true}
	state.mark("model-a", requestClassSuccess)
	_, _, class, _ := state.snapshot(http.StatusBadGateway)
	if class != requestClassProvider5xx {
		t.Fatalf("class = %q, want %q", class, requestClassProvider5xx)
	}
}

func TestInferenceOutcomeStartsBeforeWrappedHandler(t *testing.T) {
	s := &Server{}
	var started time.Time
	h := s.inferenceOutcome(func(w http.ResponseWriter, r *http.Request) {
		var ok bool
		started, ok = inferenceRequestStartedAt(r.Context())
		if !ok {
			t.Error("request start missing from context")
		}
		w.WriteHeader(http.StatusNoContent)
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	received := time.Now()
	h(httptest.NewRecorder(), req)
	if started.IsZero() || started.Before(received.Add(-time.Second)) || started.After(time.Now()) {
		t.Fatalf("invalid request start %v", started)
	}
}

func TestStatusWriterImplicitStatus(t *testing.T) {
	recorder := httptest.NewRecorder()
	sw := &statusWriter{ResponseWriter: recorder}
	if _, err := sw.Write([]byte("ok")); err != nil {
		t.Fatal(err)
	}
	if sw.status != http.StatusOK {
		t.Fatalf("status = %d, want 200", sw.status)
	}
}
