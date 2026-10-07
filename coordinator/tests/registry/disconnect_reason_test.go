package registry_test

import (
	"testing"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestClassifyPeerClose(t *testing.T) {
	cases := []struct {
		name   string
		status websocket.StatusCode
		oom    bool
		want   production.DisconnectReason
	}{
		{"normal 1000 is a graceful peer close", websocket.StatusNormalClosure, false, production.DisconnectReasonPeerClose},
		{"going-away 1001 is a graceful peer close", websocket.StatusGoingAway, false, production.DisconnectReasonPeerClose},
		{"abnormal 1006 stays abrupt", websocket.StatusAbnormalClosure, false, production.DisconnectReasonNormal},
		{"policy violation 1008 stays abrupt", websocket.StatusPolicyViolation, false, production.DisconnectReasonNormal},
		{"no close frame is a read error", -1, false, production.DisconnectReasonReadError},
		{"oom-suspected drop", -1, true, production.DisconnectReasonOOMSuspected},
		{"oom wins over a graceful code", websocket.StatusGoingAway, true, production.DisconnectReasonOOMSuspected},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := production.ClassifyPeerClose(tc.status, tc.oom); got != tc.want {
				t.Fatalf("ClassifyPeerClose(%d, %v) = %q, want %q", tc.status, tc.oom, got, tc.want)
			}
		})
	}
}

// TestDisconnectWithReason_FlushCause: the pending-request flush carries the
// health-neutral restart cause + provider_restart reason ONLY for a graceful
// peer close; every abrupt path (read error, OOM, legacy Disconnect) keeps the
// striking provider_disconnected cause with no reason.
func TestDisconnectWithReason_FlushCause(t *testing.T) {
	cases := []struct {
		name       string
		disconnect func(r *production.Registry, id string)
		wantCause  protocol.CoordinatorInferenceErrorCause
		wantReason string
	}{
		{"graceful peer close", func(r *production.Registry, id string) {
			r.DisconnectWithReason(id, production.DisconnectReasonPeerClose)
		},
			protocol.CoordinatorCauseProviderRestart, protocol.InferenceErrorReasonProviderRestart},
		{"read error", func(r *production.Registry, id string) {
			r.DisconnectWithReason(id, production.DisconnectReasonReadError)
		},
			protocol.CoordinatorCauseProviderDisconnected, ""},
		{"oom suspected", func(r *production.Registry, id string) {
			r.DisconnectWithReason(id, production.DisconnectReasonOOMSuspected)
		},
			protocol.CoordinatorCauseProviderDisconnected, ""},
		{"legacy Disconnect", func(r *production.Registry, id string) { r.Disconnect(id) },
			protocol.CoordinatorCauseProviderDisconnected, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			msg := testRegisterMessage()
			msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
			p := r.Register("prov", nil, msg)
			pr := &production.PendingRequest{
				RequestID: "req-1",
				Model:     "m",
				ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
			}
			p.AddPending(pr)

			tc.disconnect(r, "prov")

			if r.GetProvider("prov") != nil {
				t.Fatalf("provider still registered after disconnect")
			}
			got, ok := <-pr.ErrorCh
			if !ok {
				t.Fatalf("pending request received no flushed terminal")
			}
			if got.CoordinatorCause != tc.wantCause {
				t.Errorf("CoordinatorCause = %q, want %q", got.CoordinatorCause, tc.wantCause)
			}
			if got.ErrorReason != tc.wantReason {
				t.Errorf("ErrorReason = %q, want %q", got.ErrorReason, tc.wantReason)
			}
			if got.StatusCode != 502 || got.Error != "provider disconnected" {
				t.Errorf("flush = %d %q, want 502 \"provider disconnected\"", got.StatusCode, got.Error)
			}
			if !got.CoordinatorCause.IsProviderDisconnect() {
				t.Errorf("cause %q must classify as a provider disconnect", got.CoordinatorCause)
			}
		})
	}
}
