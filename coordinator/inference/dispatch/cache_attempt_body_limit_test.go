package dispatch

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLegacyCacheIsolationOverflowIsPayloadTooLarge(t *testing.T) {
	const prefix = `{"payload":"`
	const suffix = `"}`
	rawBody := []byte(prefix +
		strings.Repeat("x", MaxInferenceBodyBytes-len(prefix)-len(suffix)) +
		suffix)
	if len(rawBody) != MaxInferenceBodyBytes {
		t.Fatalf("fixture body = %d bytes, want %d", len(rawBody), MaxInferenceBodyBytes)
	}

	_, err := bodyForCacheAttempt(rawBody, false, nil, &registry.PendingRequest{
		LegacyCacheBustKey: "legacy-isolation-key",
	})
	if !errors.Is(err, ErrProviderBodyTooLarge) {
		t.Fatalf("bodyForCacheAttempt error = %v, want errProviderBodyTooLarge", err)
	}
	if got := OversizedProviderBodyBytes(err); got <= MaxInferenceBodyBytes {
		t.Fatalf("oversized body bytes = %d, want > %d", got, MaxInferenceBodyBytes)
	}
	if got := dispatchErrorClass(err.Error()); got != attempt.ErrorClassClientError {
		t.Fatalf("dispatch error class = %q, want %s", got, attempt.ErrorClassClientError)
	}
	traits, traitsErr := RoutingTraitsForProviderBody(false, rawBody, false)
	if !errors.Is(traitsErr, ErrProviderBodyTooLarge) ||
		traits.MinPrefixCacheProtocol != 1 {
		t.Fatalf("admission traits = %+v, err=%v; want protocol floor 1", traits, traitsErr)
	}
	outcome := attempt.RouteOutcome("error", dispatchErrorClass(err.Error()), http.StatusRequestEntityTooLarge)
	if outcome.ErrorReason != attempt.ErrorReasonClientError {
		t.Fatalf("route error reason = %q, want %s", outcome.ErrorReason, attempt.ErrorReasonClientError)
	}

	state := &execution{
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
	bodyBytes, preflightErr := minimumLegacyCacheBustOverflow(rawBody, false)
	state.noteProviderBodyTooLarge(preflightErr.Error(), bodyBytes)
	state.latchProviderBodyTooLarge(state.providerBodyTooLargeErr)
	if !state.terminalClientError ||
		state.terminalClientErrorCode != http.StatusRequestEntityTooLarge ||
		state.terminalClientErrorReason != "payload_too_large" ||
		state.lastErrCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("payload-too-large dispatch state = %+v", state)
	}
	rejection := state.rejection(
		"dispatch", "payload_too_large", http.StatusRequestEntityTooLarge, 0)
	if rejection.RequestBodyBytes != state.providerBodyTooLargeBytes ||
		!rejection.ServabilityComputed ||
		rejection.CandidateCount != 0 {
		t.Fatalf("rejection accounting = %+v, want exact bytes and could_have_served=false",
			rejection)
	}
}

func TestBodyAtLimitWithoutLegacyCacheIsolationRemainsAccepted(t *testing.T) {
	const prefix = `{"payload":"`
	const suffix = `"}`
	rawBody := []byte(prefix +
		strings.Repeat("x", MaxInferenceBodyBytes-len(prefix)-len(suffix)) +
		suffix)

	sealed, err := bodyForCacheAttempt(rawBody, false, nil, &registry.PendingRequest{})
	if err != nil {
		t.Fatalf("bodyForCacheAttempt: %v", err)
	}
	if len(sealed) != MaxInferenceBodyBytes {
		t.Fatalf("sealed body = %d bytes, want %d", len(sealed), MaxInferenceBodyBytes)
	}
}

func TestVisionPreflightKeepsLegacyProviderWhenPenaltyStrippingFits(t *testing.T) {
	const prefix = `{"payload":"`
	const penaltyPrefix = `","repetition_penalty":"`
	const penaltyValueBytes = 256
	const suffix = `"}`
	const providerMutationBytes = 100
	fillerBytes := MaxInferenceBodyBytes + providerMutationBytes -
		len(prefix) - len(penaltyPrefix) - penaltyValueBytes - len(suffix)
	rawBody := []byte(prefix +
		strings.Repeat("x", fillerBytes) +
		penaltyPrefix +
		strings.Repeat("y", penaltyValueBytes) +
		suffix)
	if len(rawBody) != MaxInferenceBodyBytes+providerMutationBytes {
		t.Fatalf("fixture body = %d bytes, want %d",
			len(rawBody), MaxInferenceBodyBytes+providerMutationBytes)
	}

	if _, err := minimumLegacyCacheBustOverflow(rawBody, false); !errors.Is(err, ErrProviderBodyTooLarge) {
		t.Fatalf("unstripped body error = %v, want errProviderBodyTooLarge", err)
	}
	if _, err := minimumLegacyCacheBustOverflow(rawBody, true); err != nil {
		t.Fatalf("vision body should fit after mandatory legacy penalty stripping: %v", err)
	}
	legacyBody, err := bodyForCacheAttempt(
		rawBody, true, &registry.Provider{Version: "0.6.6"}, &registry.PendingRequest{})
	if err != nil || len(legacyBody) > MaxInferenceBodyBytes {
		t.Fatalf("legacy transformed body size=%d err=%v", len(legacyBody), err)
	}
	if _, err := bodyForCacheAttempt(
		rawBody, true, &registry.Provider{Version: penaltySafeProviderVersion},
		&registry.PendingRequest{}); !errors.Is(err, ErrProviderBodyTooLarge) {
		t.Fatalf("untransformed modern body error=%v, want payload-too-large", err)
	}
	if _, err := providerBodySizeError(
		rawBody, true, &registry.Provider{Version: "0.6.6"}); err != nil {
		t.Fatalf("legacy pre-pricing size check rejected transformed body: %v", err)
	}
	if _, err := providerBodySizeError(
		rawBody, true, &registry.Provider{
			Version: penaltySafeProviderVersion, PrefixCacheProtocol: 1,
		}); !errors.Is(err, ErrProviderBodyTooLarge) {
		t.Fatalf("modern pre-pricing size check error=%v, want payload-too-large", err)
	}

	state := &execution{rawBody: rawBody, requiresVision: true}
	state.preflightLegacyCacheBust()
	if state.minPrefixCacheProtocol != 0 || state.providerBodyTooLargeErr != "" {
		t.Fatalf("vision preflight incorrectly excluded protocol-0 provider: %+v", state)
	}
	state.lastErr = "prior provider failure"
	state.lastErrReason = "jinja_template_error"
	state.noteProviderBodyTooLargeFor(
		&registry.Provider{ID: "newer-v0", Version: penaltySafeProviderVersion},
		"provider-specific overflow",
	)
	if state.minPrefixCacheProtocol != 0 {
		t.Fatalf("one provider-specific overflow excluded all protocol-0 fallbacks: %+v", state)
	}
	if !state.shouldQueueCompatibleProvider(registry.RoutingDecision{CapacityRejections: 1}) {
		t.Fatal("provider-specific overflow did not preserve queueing for a compatible busy fallback")
	}
	outcome := state.errorRoutingOutcomeFor(
		&registry.PendingRequest{}, "error", attempt.ErrorClassClientError, http.StatusRequestEntityTooLarge)
	if outcome.ErrorReason != attempt.ErrorReasonClientError {
		t.Fatalf("overflow route inherited stale reason %q", outcome.ErrorReason)
	}
	excluded := state.excludedProviderIDs()
	if len(excluded) != 1 || excluded[0] != "newer-v0" {
		t.Fatalf("queued fallback exclusions = %v, want [newer-v0]", excluded)
	}
}
