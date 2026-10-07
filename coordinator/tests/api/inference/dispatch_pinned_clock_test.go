package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	dispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDispatchOneProviderUsesPinnedExpiredClockWithoutRecomputing(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "deadline-expired-before-wire-model"
	provider := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-expired", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: fullServeScript(model),
	})

	req := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(buildChatBody(t, model, false, nil)),
	)
	selected, pending, _, _, dispatchErr, dispatchErrCode := srv.NewDispatcher().Dispatch(
		req,
		model,
		model,
		[]byte(buildChatBody(t, model, false, nil)),
		"test-key",
		nil,
		0,
		8,
		10*time.Millisecond,
		64,
		registry.TokenAdmission{},
		false,
		registry.RequestTraits{},
		nil,
		false, dispatch.Scope{}, // The pinned 10ms request clock is expired, while recomputing this
		// ordinary model from the server's 5s default would still allow a send.
		&registry.RequestTiming{ReceivedAt: time.Now().Add(-50 * time.Millisecond)},
		false,
		registry.CachePlan{}, dispatch.NewExclusions(), 0,
		nil,
		"",
		nil,
		nil, true, srv.NewDispatcher().ScanReserver(model),
	)
	if selected != nil || pending != nil {
		t.Fatalf("expired dispatch selected provider=%v pending=%v", selected, pending)
	}
	if dispatchErr != providerwire.DeadlineExpiredMessage ||
		dispatchErrCode != http.StatusGatewayTimeout {
		t.Fatalf(
			"expired dispatch = (%q,%d), want (%q,504)",
			dispatchErr, dispatchErrCode, providerwire.DeadlineExpiredMessage)
	}
	time.Sleep(50 * time.Millisecond)
	if got := provider.dispatchCount(); got != 0 {
		t.Fatalf("expired request reached provider wire %d time(s), want 0", got)
	}
}
