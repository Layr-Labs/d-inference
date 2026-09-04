package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestDeadlineWedgeSkipStopsDispatchingToARefusingIdleSlot runs two real
// in-process WebSocket providers: "wedged" (the cheaper box) refuses every
// dispatch with deadline_unreachable while idle; "serving" serves. Deadline
// refusals are health-neutral, so without the wedge skip every request's
// first attempt lands on the wedged box (it keeps ranking first). With the
// switch on, the pair is skipped after N = deadlineWedgeThreshold refusals
// and later requests land on the serving box in ONE attempt; the serving box
// is never skipped. With the switch off (shadow) the wedged box keeps
// receiving every first attempt and the would-be skips are counted.
func TestDeadlineWedgeSkipStopsDispatchingToARefusingIdleSlot(t *testing.T) {
	const threshold = 5 // registry.deadlineWedgeThreshold
	run := func(t *testing.T, enabled bool) (wedgedDispatches int64, packets []string) {
		reg, _, srv, ts := setupTTFTFailoverServer(t)
		reg.SetDeadlineWedgeSkipEnabled(enabled)
		collector := withTestDD(t, srv)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		const model = "deadline-wedge-model"

		var wedged atomic.Int64
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "wedged", Version: "0.8.10", DecodeTPS: 200,
			Models: []failoverModelSpec{{ID: model}},
			Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
				wedged.Add(1)
				fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
			},
		})
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "serving", Version: "0.8.10", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}},
			Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
				fp.serveFull(ctx, req, model, markerFor(fp.name))
			},
		})

		// max_tokens 4096 keeps the two boxes' costs (20 s vs 41 s of decode)
		// outside the near-tie window, so the wedged box deterministically
		// ranks first whenever it is routable.
		body, err := json.Marshal(map[string]any{
			"model":      model,
			"messages":   []map[string]any{{"role": "user", "content": "wedge test prompt"}},
			"stream":     true,
			"max_tokens": 4096,
		})
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < threshold+2; i++ {
			status, resp, err := postChat(ctx, ts.URL, "test-key", string(body))
			if err != nil {
				t.Fatalf("request %d: %v", i, err)
			}
			assertCleanFailoverStream(t, status, resp, markerFor("serving"))
		}
		return wedged.Load(), flushDD(t, srv, collector)
	}

	t.Run("switch on: skipped after N refusals", func(t *testing.T) {
		dispatches, packets := run(t, true)
		if dispatches != threshold {
			t.Fatalf("wedged box received %d dispatches over %d requests, want exactly %d (skipped afterwards)", dispatches, threshold+2, threshold)
		}
		if !hasSeries(packets, "routing.deadline_wedge_skip:1|c|", "event:armed") {
			t.Fatalf("missing armed event; packets: %v", packets)
		}
	})
	t.Run("switch off: shadow only", func(t *testing.T) {
		dispatches, packets := run(t, false)
		if dispatches != threshold+2 {
			t.Fatalf("wedged box received %d dispatches, want %d (shadow mode never skips)", dispatches, threshold+2)
		}
		if !hasSeries(packets, "routing.deadline_wedge_skip:1|c|", "event:armed") {
			t.Fatalf("missing armed event in shadow mode; packets: %v", packets)
		}
	})
}
