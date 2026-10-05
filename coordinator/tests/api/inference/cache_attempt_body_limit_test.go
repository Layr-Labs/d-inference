package inference_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	profilepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
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

	_, err := providerwire.BodyForCacheAttempt(rawBody, "legacy-isolation-key")
	if !errors.Is(err, providerwire.ErrBodyTooLarge) {
		t.Fatalf("bodyForCacheAttempt error = %v, want errProviderBodyTooLarge", err)
	}
	if got := providerwire.OversizedBodyBytes(err); got <= inreq.MaxInferenceBodyBytes {
		t.Fatalf("oversized body bytes = %d, want > %d", got, inreq.MaxInferenceBodyBytes)
	}
	if got := profilepolicy.DispatchErrorClass(err.Error()); got != routeoutcome.ErrorClassClientError {
		t.Fatalf("dispatch error class = %q, want %s", got, routeoutcome.ErrorClassClientError)
	}
	traits, traitsErr := providerwire.RoutingTraits(false, rawBody)
	if !errors.Is(traitsErr, providerwire.ErrBodyTooLarge) ||
		traits.MinPrefixCacheProtocol != 1 {
		t.Fatalf("admission traits = %+v, err=%v; want protocol floor 1", traits, traitsErr)
	}
	outcome := routeoutcome.PendingRouteOutcome(nil, "error", profilepolicy.DispatchErrorClass(err.Error()), http.StatusRequestEntityTooLarge)
	if outcome.ErrorReason != failure.ErrorReasonClientError {
		t.Fatalf("route error reason = %q, want %s", outcome.ErrorReason, failure.ErrorReasonClientError)
	}

	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	state := inference.PrimaryHistory{}
	traits, _ = providerwire.RoutingTraits(false, rawBody)
	if state.Terminal.ClientStatus != 0 ||
		state.Overflow.Message != "" ||
		traits.MinPrefixCacheProtocol != 1 ||
		state.Failure.Message.StatusCode != 0 {
		t.Fatalf("hypothetical overflow was incorrectly latched: %+v", state)
	}
	bodyBytes, preflightErr := providerwire.MinimumLegacyCacheBustOverflow(rawBody)
	state = state.WithBodyOverflow(preflightErr.Error(), bodyBytes)
	state = state.RejectBodyOverflow(state.Overflow.Message)
	if state.Terminal.ClientStatus == 0 ||
		state.Terminal.ClientStatus != http.StatusRequestEntityTooLarge ||
		state.Terminal.ClientReason != "payload_too_large" ||
		state.Failure.Message.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("payload-too-large dispatch state = %+v", state)
	}
	prepared := rejection.BuildDispatch(r, rejection.DispatchMetadata{OverflowBodyBytes: state.Overflow.Bytes},
		"dispatch", "payload_too_large", http.StatusRequestEntityTooLarge, 0, nil)
	if prepared.Record.RequestBodyBytes != state.Overflow.Bytes ||
		!prepared.Servability.Computed ||
		prepared.Record.CandidateCount != 0 {
		t.Fatalf("rejection accounting = %+v, want exact bytes and could_have_served=false", prepared)
	}
}

func TestProviderSpecificOverflowKeepsCompatibleFallbacks(t *testing.T) {
	rawBody := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	state := inference.PrimaryHistory{}
	traits, _ := providerwire.RoutingTraits(false, rawBody)
	if traits.MinPrefixCacheProtocol != 0 || state.Overflow.Message != "" {
		t.Fatalf("preflight excluded protocol-0 providers for a small body: %+v", state)
	}
	state.Failure.Message.Error = "prior provider failure"
	state.Failure.Message.ErrorReason = "jinja_template_error"
	exclusions := providerdispatch.NewExclusions()
	state = state.ProviderBodyRejected(rawBody,
		&registry.Provider{ID: "newer-v0"},
		"provider-specific overflow", exclusions,
	)
	if traits.MinPrefixCacheProtocol != 0 {
		t.Fatalf("one provider-specific overflow excluded all protocol-0 fallbacks: %+v", state)
	}
	if !state.QueueCompatible(registry.RoutingDecision{CapacityRejections: 1}) {
		t.Fatal("provider-specific overflow did not preserve queueing for a compatible busy fallback")
	}
	if state.QueueCompatible(registry.RoutingDecision{}) {
		t.Fatal("provider-specific overflow queued with no busy compatible provider")
	}
	outcome := retry.ErrorRouteOutcome(&registry.PendingRequest{}, "error", routeoutcome.ErrorClassClientError, state.Failure.Message)
	if outcome.ErrorReason != failure.ErrorReasonClientError {
		t.Fatalf("overflow route inherited stale reason %q", outcome.ErrorReason)
	}
	excluded := exclusions.IDs()
	if len(excluded) != 1 || excluded[0] != "newer-v0" {
		t.Fatalf("queued fallback exclusions = %v, want [newer-v0]", excluded)
	}
}
