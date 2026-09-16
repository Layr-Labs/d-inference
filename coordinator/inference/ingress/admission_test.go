package ingress

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAdmissionDoesNotInvent413WithoutIncompatibleProvider(t *testing.T) {
	s := newTestAdmissionController(t)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	traits := registry.RequestTraits{MinPrefixCacheProtocol: 1}
	body := []byte(`{"model":"overflow-model","padding":"` + strings.Repeat("x", maxInferenceBodyBytes-len(`{"model":"overflow-model","padding":""}`)) + `"}`)
	_, sizeErr := dispatch.RoutingTraitsForProviderBody(false, body, false)
	if !errors.Is(sizeErr, dispatch.ErrProviderBodyTooLarge) {
		t.Fatalf("fixture did not produce legacy-sealing overflow: %v", sizeErr)
	}
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
			policy:                    dispatch.RoutePolicy{Prefer: true, OwnerAccountID: "owner"},
			refundReservation:         func() { preferRefunded = true },
		},
	)
	if preferHandled || preferRefunded ||
		strings.Contains(preferRecorder.Body.String(), "payload_too_large") {
		t.Fatalf("empty prefer fleet handled=%v refunded=%v body=%s",
			preferHandled, preferRefunded, preferRecorder.Body.String())
	}
}
