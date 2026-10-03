package inference

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLegacyCacheIsolationOverflowIsPayloadTooLarge(t *testing.T) {
	const prefix = `{"payload":"`
	const suffix = `"}`
	rawBody := []byte(prefix +
		strings.Repeat("x", inreq.MaxInferenceBodyBytes-len(prefix)-len(suffix)) +
		suffix)
	if len(rawBody) != inreq.MaxInferenceBodyBytes {
		t.Fatalf("fixture body = %d bytes, want %d", len(rawBody), inreq.MaxInferenceBodyBytes)
	}

	_, err := bodyForCacheAttempt(rawBody, &registry.PendingRequest{
		LegacyCacheBustKey: "legacy-isolation-key",
	})
	if !errors.Is(err, errProviderBodyTooLarge) {
		t.Fatalf("bodyForCacheAttempt error = %v, want errProviderBodyTooLarge", err)
	}
	if got := oversizedProviderBodyBytes(err); got <= inreq.MaxInferenceBodyBytes {
		t.Fatalf("oversized body bytes = %d, want > %d", got, inreq.MaxInferenceBodyBytes)
	}
	if got := dispatchErrorClass(err.Error()); got != errorClassClientError {
		t.Fatalf("dispatch error class = %q, want %s", got, errorClassClientError)
	}
	traits, traitsErr := routingTraitsForProviderBody(false, rawBody)
	if !errors.Is(traitsErr, errProviderBodyTooLarge) ||
		traits.MinPrefixCacheProtocol != 1 {
		t.Fatalf("admission traits = %+v, err=%v; want protocol floor 1", traits, traitsErr)
	}
	outcome := routeOutcome("error", dispatchErrorClass(err.Error()), http.StatusRequestEntityTooLarge)
	if outcome.ErrorReason != errorReasonClientError {
		t.Fatalf("route error reason = %q, want %s", outcome.ErrorReason, errorReasonClientError)
	}

	state := &dispatchState{
		r:       httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil),
		rawBody: rawBody,
	}
	state.preflightLegacyCacheBust()
	if state.terminalClientError ||
		state.providerBodyTooLargeErr != "" ||
		state.minPrefixCacheProtocol != 1 ||
		state.lastErrCode != 0 {
		t.Fatalf("hypothetical overflow was incorrectly latched: %+v", state)
	}
	bodyBytes, preflightErr := minimumLegacyCacheBustOverflow(rawBody)
	state.noteProviderBodyTooLarge(preflightErr.Error(), bodyBytes)
	state.latchProviderBodyTooLarge(state.providerBodyTooLargeErr)
	if !state.terminalClientError ||
		state.terminalClientErrorCode != http.StatusRequestEntityTooLarge ||
		state.terminalClientErrorReason != "payload_too_large" ||
		state.lastErrCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("payload-too-large dispatch state = %+v", state)
	}
	rejection := state.rejectionInfo(
		"dispatch", "payload_too_large", http.StatusRequestEntityTooLarge, 0)
	if rejection.requestBodyBytes != state.providerBodyTooLargeBytes ||
		!rejection.servabilityComputed ||
		rejection.candidateCount != 0 {
		t.Fatalf("rejection accounting = %+v, want exact bytes and could_have_served=false",
			rejection)
	}
}

func TestBodyAtLimitWithoutLegacyCacheIsolationRemainsAccepted(t *testing.T) {
	const prefix = `{"payload":"`
	const suffix = `"}`
	rawBody := []byte(prefix +
		strings.Repeat("x", inreq.MaxInferenceBodyBytes-len(prefix)-len(suffix)) +
		suffix)

	sealed, err := bodyForCacheAttempt(rawBody, &registry.PendingRequest{})
	if err != nil {
		t.Fatalf("bodyForCacheAttempt: %v", err)
	}
	if len(sealed) != inreq.MaxInferenceBodyBytes {
		t.Fatalf("sealed body = %d bytes, want %d", len(sealed), inreq.MaxInferenceBodyBytes)
	}
}

func TestAdmissionDoesNotInvent413WithoutIncompatibleProvider(t *testing.T) {
	s := newTestServerForDispatch(t)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	traits := registry.RequestTraits{MinPrefixCacheProtocol: 1}
	sizeErr := &providerBodyTooLargeError{size: inreq.MaxInferenceBodyBytes + 63}
	refunded := false
	_, handled := s.runInferenceAdmission(
		recorder,
		request,
		map[string]any{"model": "overflow-model"},
		inferenceAdmissionParams{
			model:                     "overflow-model",
			publicModel:               "overflow-model",
			traits:                    &traits,
			traitsForModel:            func(string) registry.RequestTraits { return traits },
			providerBodyErrorForModel: func(string) error { return sizeErr },
			refundReservation:         func() { refunded = true },
		},
	)
	// An empty fleet sheds as transient capacity (429 + Retry-After), never as a
	// request-shape error: nothing about this request is too large.
	if !handled || !refunded || recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("admission handled=%v refunded=%v status=%d body=%s",
			handled, refunded, recorder.Code, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), `"code":"payload_too_large"`) {
		t.Fatalf("empty fleet was misclassified as payload_too_large: %s", recorder.Body.String())
	}

	preferRecorder := httptest.NewRecorder()
	preferRefunded := false
	_, preferHandled := s.runInferenceAdmission(
		preferRecorder,
		request,
		map[string]any{"model": "overflow-model"},
		inferenceAdmissionParams{
			model:                     "overflow-model",
			publicModel:               "overflow-model",
			traits:                    &traits,
			traitsForModel:            func(string) registry.RequestTraits { return traits },
			providerBodyErrorForModel: func(string) error { return sizeErr },
			policy:                    selfRoutePolicy{prefer: true, ownerAccountID: "owner"},
			refundReservation:         func() { preferRefunded = true },
		},
	)
	if preferHandled || preferRefunded ||
		strings.Contains(preferRecorder.Body.String(), "payload_too_large") {
		t.Fatalf("empty prefer fleet handled=%v refunded=%v body=%s",
			preferHandled, preferRefunded, preferRecorder.Body.String())
	}
}

// TestProviderSpecificOverflowKeepsCompatibleFallbacks: one provider's
// payload-too-large dispatch error excludes only that provider. It must not
// latch a fleet-wide protocol floor, and it must keep the request queueable
// for a compatible busy fallback.
func TestProviderSpecificOverflowKeepsCompatibleFallbacks(t *testing.T) {
	rawBody := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	state := &dispatchState{rawBody: rawBody}
	state.preflightLegacyCacheBust()
	if state.minPrefixCacheProtocol != 0 || state.providerBodyTooLargeErr != "" {
		t.Fatalf("preflight excluded protocol-0 providers for a small body: %+v", state)
	}
	state.lastErr = "prior provider failure"
	state.lastErrReason = "jinja_template_error"
	state.noteProviderBodyTooLargeFor(
		&registry.Provider{ID: "newer-v0"},
		"provider-specific overflow",
	)
	if state.minPrefixCacheProtocol != 0 {
		t.Fatalf("one provider-specific overflow excluded all protocol-0 fallbacks: %+v", state)
	}
	if !state.shouldQueueCompatibleProvider(registry.RoutingDecision{CapacityRejections: 1}) {
		t.Fatal("provider-specific overflow did not preserve queueing for a compatible busy fallback")
	}
	if state.shouldQueueCompatibleProvider(registry.RoutingDecision{}) {
		t.Fatal("provider-specific overflow queued with no busy compatible provider")
	}
	outcome := state.errorRoutingOutcomeFor(
		&registry.PendingRequest{}, "error", errorClassClientError, http.StatusRequestEntityTooLarge)
	if outcome.ErrorReason != errorReasonClientError {
		t.Fatalf("overflow route inherited stale reason %q", outcome.ErrorReason)
	}
	excluded := state.excludedProviderIDs()
	if len(excluded) != 1 || excluded[0] != "newer-v0" {
		t.Fatalf("queued fallback exclusions = %v, want [newer-v0]", excluded)
	}
}
