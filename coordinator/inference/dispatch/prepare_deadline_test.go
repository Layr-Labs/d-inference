package dispatch

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPrepareProviderUsesPinnedExpiredClock(t *testing.T) {
	srv := newTestController(t)
	const model = "deadline-expired-before-wire-model"
	makeRoutableProvider(t, srv.deps.Registry(), "expired-clock", model)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	selected, pending, _, _, dispatchErr, dispatchErrCode := srv.dispatchOneProvider(
		req,
		model,
		model,
		[]byte(`{"model":"deadline-expired-before-wire-model","messages":[]}`),
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
		false,
		RoutePolicy{},
		// The pinned 10ms request clock is expired, while recomputing this
		// ordinary model from the server's 5s default would still allow a send.
		&registry.RequestTiming{ReceivedAt: time.Now().Add(-50 * time.Millisecond)},
		false,
		registry.CachePlan{},
		map[string]struct{}{},
		0,
		nil,
		"",
		nil,
		nil,
	)
	if selected != nil || pending != nil {
		t.Fatalf("expired dispatch selected provider=%v pending=%v", selected, pending)
	}
	if dispatchErr != errFirstContentDeadlineExpired ||
		dispatchErrCode != http.StatusGatewayTimeout {
		t.Fatalf(
			"expired dispatch = (%q,%d), want (%q,504)",
			dispatchErr, dispatchErrCode, errFirstContentDeadlineExpired)
	}
}
