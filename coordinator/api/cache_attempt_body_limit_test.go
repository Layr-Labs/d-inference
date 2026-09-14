package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
		"x", dispatch.MaxInferenceBodyBytes-len(prefix)-len(suffix)) + suffix
	if len(body) != dispatch.MaxInferenceBodyBytes {
		t.Fatalf("fixture body = %d, want %d", len(body), dispatch.MaxInferenceBodyBytes)
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
