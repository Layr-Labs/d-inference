package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestSpeculationAllowedRejectsEveryFundedShape(t *testing.T) {
	tests := []struct {
		name               string
		allow              bool
		reservedMicroUSD   int64
		serviceReservation bool
		want               bool
	}{
		{name: "paid ledger reservation", allow: true, reservedMicroUSD: 1, want: false},
		{name: "service reservation", allow: true, serviceReservation: true, want: false},
		{name: "paid policy disabled", allow: false, want: false},
		{name: "free self route", allow: true, want: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state := dispatchState{
				allowSpeculation:   test.allow,
				reservedMicroUSD:   test.reservedMicroUSD,
				serviceReservation: test.serviceReservation,
			}
			if got := state.speculationAllowed(); got != test.want {
				t.Fatalf("speculationAllowed() = %t, want %t", got, test.want)
			}
		})
	}
}

func TestPaidRequestDoesNotLaunchSpeculativeBackup(t *testing.T) {
	previousDeadlineBase := ttftLiveDeadlineBaseMs
	SetTTFTLiveDeadlineBaseMs(300)
	t.Cleanup(func() { SetTTFTLiveDeadlineBaseMs(previousDeadlineBase) })

	srv, _, _ := billingTestServer(t)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const model = "paid-no-speculation-model"
	primary := startFailoverProvider(t, ctx, ts, srv.registry, failoverProviderConfig{
		Name: "primary", Version: "0.7.5", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, provider *failoverProvider, request protocol.InferenceRequestMessage, _ []byte) {
			time.Sleep(220 * time.Millisecond)
			provider.serveFull(ctx, request, model, markerFor(provider.name))
		},
	})
	backup := startFailoverProvider(t, ctx, ts, srv.registry, failoverProviderConfig{
		Name: "backup", Version: "0.7.5", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}},
		Script: fullServeScript(model),
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("paid chat: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("primary")) {
		t.Fatalf("response was not served by the selected primary: %s", body)
	}
	if got := primary.dispatchCount(); got != 1 {
		t.Fatalf("primary dispatches = %d, want 1", got)
	}
	if got := backup.dispatchCount(); got != 0 {
		t.Fatalf("paid request launched %d speculative backup dispatch(es), want 0", got)
	}
}
