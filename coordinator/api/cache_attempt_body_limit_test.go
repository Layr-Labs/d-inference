package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAdmissionDoesNotInvent413WithoutIncompatibleProvider(t *testing.T) {
	s := newTestServerForDispatch(t)
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
			policy:                    selfRoutePolicy{Prefer: true, OwnerAccountID: "owner"},
			refundReservation:         func() { preferRefunded = true },
		},
	)
	if preferHandled || preferRefunded ||
		strings.Contains(preferRecorder.Body.String(), "payload_too_large") {
		t.Fatalf("empty prefer fleet handled=%v refunded=%v body=%s",
			preferHandled, preferRefunded, preferRecorder.Body.String())
	}
}

func TestAdmissionReturns413ForActualProtocolZeroIncompatibility(t *testing.T) {
	reg, _, server := setupFailoverServer(t)
	// Allow race-instrumented decoding of a maximum-size body on loaded runners.
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	const model = "overflow-protocol-zero-model"
	provider := startFailoverProvider(t, ctx, server, reg, failoverProviderConfig{
		Name:      "protocol-zero",
		Version:   "0.6.20",
		DecodeTPS: 100,
		Models:    []failoverModelSpec{{ID: model}},
		Script: func(context.Context, *failoverProvider, protocol.InferenceRequestMessage, []byte) {
			t.Error("protocol-zero provider received a body that cannot fit its wire frame")
		},
	})
	const prefix = `{"model":"overflow-protocol-zero-model","messages":[{"role":"user","content":"`
	const suffix = `"}],"max_tokens":1}`
	body := prefix + strings.Repeat(
		"x", maxInferenceBodyBytes-len(prefix)-len(suffix)) + suffix
	if len(body) != maxInferenceBodyBytes {
		t.Fatalf("fixture body = %d, want %d", len(body), maxInferenceBodyBytes)
	}
	request, err := http.NewRequestWithContext(
		ctx, http.MethodPost, server.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusRequestEntityTooLarge ||
		!strings.Contains(string(responseBody), `"code":"payload_too_large"`) {
		t.Fatalf("status=%d body=%s", response.StatusCode, responseBody)
	}
	if provider.dispatchCount() != 0 {
		t.Fatalf("incompatible provider received %d dispatches", provider.dispatchCount())
	}
}
