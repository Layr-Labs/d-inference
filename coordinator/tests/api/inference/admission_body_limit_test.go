package inference_test

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAdmissionDoesNotInvent413WithoutIncompatibleProvider(t *testing.T) {
	s := newTestServerForDispatch(t)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	traits := registry.RequestTraits{MinPrefixCacheProtocol: 1}
	_, sizeErr := providerwire.BodyForCacheAttempt(make([]byte, inreq.MaxInferenceBodyBytes+63), "")
	if !errors.Is(sizeErr, providerwire.ErrBodyTooLarge) {
		t.Fatal("fixture did not produce an oversized provider body error")
	}
	refunded := false
	result := runAdmission(
		s.NewAdmission(),
		recorder,
		request,
		map[string]any{"model": "overflow-model"},
		inference.AdmissionRequest{
			Model:                     "overflow-model",
			PublicModel:               "overflow-model",
			Traits:                    &traits,
			TraitsForModel:            func(string) registry.RequestTraits { return traits },
			ProviderBodyErrorForModel: func(string) error { return sizeErr },
			RefundReservation:         func() { refunded = true },
		},
	)
	handled := result.Handled
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
	preferResult := runAdmission(
		s.NewAdmission(),
		preferRecorder,
		request,
		map[string]any{"model": "overflow-model"},
		inference.AdmissionRequest{
			Model:                     "overflow-model",
			PublicModel:               "overflow-model",
			Traits:                    &traits,
			TraitsForModel:            func(string) registry.RequestTraits { return traits },
			ProviderBodyErrorForModel: func(string) error { return sizeErr },
			Policy:                    access.SelfRoutePolicy{Prefer: true, OwnerAccountID: "owner"},
			RefundReservation:         func() { preferRefunded = true },
		},
	)
	preferHandled := preferResult.Handled
	if preferHandled || preferRefunded ||
		strings.Contains(preferRecorder.Body.String(), "payload_too_large") {
		t.Fatalf("empty prefer fleet handled=%v refunded=%v body=%s",
			preferHandled, preferRefunded, preferRecorder.Body.String())
	}
}
