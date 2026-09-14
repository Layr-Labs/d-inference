package dispatch

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// The API fixture retains compact-record persistence and a real provider
// completion. This owner fixture drives the queue and actual WebSocket writer
// while inspecting the dispatch history that must not enter a new profile.
func TestQueuedDispatchProfileDoesNotInheritPriorError(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	for _, priorOverflow := range []bool{false, true} {
		t.Run(fmt.Sprint(priorOverflow), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			connections := make(chan *websocket.Conn, 1)
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := websocket.Accept(w, r, nil)
				if err != nil {
					return
				}
				connections <- conn
			}))
			defer ts.Close()
			peer, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer peer.CloseNow()
			var conn *websocket.Conn
			select {
			case conn = <-connections:
			case <-ctx.Done():
				t.Fatal("provider connection was not accepted")
			}
			defer conn.CloseNow()
			c := newTestController(t)
			reg := c.deps.Registry()
			const model = "accounting-queued-dispatch"
			p := makeRoutableProvider(t, reg, "queued-provider", model, conn)
			defer reg.Disconnect(p.ID)
			capacity := func(used int64) {
				reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
					Status: "serving",
					BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64,
						Slots: []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 1, ActiveTokenBudgetUsed: used, ActiveTokenBudgetMax: 1000}}},
				})
			}
			capacity(950)
			rp := registry.NewRequestProfile(time.Now(), "queued-history", nil, 0)
			rp.CompactOnly = true
			d := &execution{
				s: c, r: httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx), w: httptest.NewRecorder(),
				model: model, publicModel: model, rawBody: []byte(`{"model":"accounting-queued-dispatch","messages":[{"role":"user","content":"hello"}],"max_tokens":64}`),
				consumerKey: "test-key", estimatedPromptTokens: 16, requestedMaxTokens: 64,
				deadline: 5 * time.Second, timing: &registry.RequestTiming{ReceivedAt: time.Now()},
				excludeProviders: map[string]struct{}{}, refundReservation: func() {}, profile: rp,
			}
			if priorOverflow {
				d.attempt = 1
				d.lastErr = ErrProviderBodyTooLarge.Error()
				d.lastErrCode = http.StatusRequestEntityTooLarge
				d.providerBodyTooLargeErr = d.lastErr
			}
			previousError, previousStatus := d.lastErr, d.lastErrCode
			result := make(chan dispatchOutcome, 1)
			go func() { result <- d.dispatchPrimary() }()
			waitForAdaptiveCondition(t, time.Second, func() bool { return reg.Queue().QueueSize(model) == 1 })
			capacity(0)
			select {
			case got := <-result:
				if got != outcomeProceed {
					t.Fatalf("dispatch outcome=%v error=%q code=%d", got, d.lastErr, d.lastErrCode)
				}
			case <-ctx.Done():
				t.Fatal("queued dispatch did not finish")
			}
			_, data, err := peer.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var wire protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &wire); err != nil {
				t.Fatal(err)
			}
			if wire.Type != protocol.TypeInferenceRequest || wire.RequestID != d.pr.RequestID || wire.EncryptedBody == nil {
				t.Fatalf("queued writer did not deliver its inference frame: %+v", wire)
			}
			ap := d.pr.Profile
			if ap == nil || ap.Get(registry.StampQueued) == 0 || ap.Get(registry.StampWriteSubmitted) == 0 || ap.Get(registry.StampWriteDone) == 0 {
				t.Fatalf("missing queued write evidence: %+v", ap)
			}
			if final, reason, _, provider, _ := ap.Outcome(); final != "" || reason != "" || provider != "" {
				t.Fatalf("successful queued dispatch inherited an error: final=%q reason=%q provider=%q", final, reason, provider)
			}
			if d.lastErr != previousError || d.lastErrCode != previousStatus {
				t.Fatalf("accounting changed routing history: error=%q status=%d", d.lastErr, d.lastErrCode)
			}
			d.finalizeProfile()
		})
	}
}
