package api

// Live tests for the load_model attribution series (warm_pool_signals.go +
// registry_metrics.go): a real provider WebSocket receives the load_model the
// swap planner sends and answers with load_model_status; the DogStatsD packets
// are captured on a UDP collector.

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// drainUntil flushes the client and collects packets until pred holds over the
// accumulated set or the deadline passes.
func drainUntil(t *testing.T, dd interface{ FlushStatsd() error }, collector *udpCollector, deadline time.Duration, pred func([]string) bool) []string {
	t.Helper()
	var packets []string
	stop := time.Now().Add(deadline)
	for {
		_ = dd.FlushStatsd()
		packets = append(packets, collector.drain()...)
		if pred(packets) {
			return packets
		}
		if time.Now().After(stop) {
			return packets
		}
	}
}

type statsdFlusher struct{ c interface{ Flush() error } }

func (f statsdFlusher) FlushStatsd() error { return f.c.Flush() }

// counterSum sums the values of every counter packet for name that carries
// all tags. DogStatsD aggregates same-tag increments into one packet
// ("name:2|c|#tags"), so packet counts undercount events.
func counterSum(packets []string, name string, tags ...string) int64 {
	var sum int64
	for _, p := range findMetrics(packets, name) {
		ok := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		// d_inference.<name>:<value>|c|#tags
		body := p[strings.Index(p, name)+len(name):]
		if !strings.HasPrefix(body, ":") {
			continue
		}
		valueEnd := strings.Index(body, "|")
		if valueEnd < 0 {
			continue
		}
		v, err := strconv.ParseInt(body[1:valueEnd], 10, 64)
		if err != nil {
			continue
		}
		sum += v
	}
	return sum
}

func hasMetricWith(packets []string, name string, tags ...string) bool {
	for _, p := range findMetrics(packets, name) {
		ok := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// TestLoadModelStatusEmitsResultMetrics drives two planner-issued loads over a
// real provider socket: the first succeeds, the second fails. Each send is a
// model_load.sent{planner:swap}; each terminal status a model_load.result
// {status} with a model_load.duration_ms sample.
func TestLoadModelStatusEmitsResultMetrics(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	const okModel, failModel = "load-metrics-ok", "load-metrics-fail"
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models: []protocol.ModelInfo{
			{ID: okModel, ModelType: "chat", Quantization: "4bit"},
			{ID: failModel, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	p := findProviderByModel(reg, okModel)
	if p == nil {
		t.Fatal("provider did not register")
	}
	reg.SetTrustLevel(p.ID, registry.TrustHardware)
	reg.RecordChallengeSuccess(p.ID)

	loads := make(chan string, 4)
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
			case protocol.TypeLoadModel:
				model, _ := raw["model_id"].(string)
				status := protocol.LoadModelStatusMessage{
					Type: protocol.TypeLoadModelStatus, ModelID: model, Status: protocol.LoadModelStatusSucceeded,
				}
				if model == failModel {
					status.Status = protocol.LoadModelStatusFailed
					status.Error = "insufficient memory to load model"
				}
				out, _ := json.Marshal(status)
				_ = conn.Write(ctx, websocket.MessageText, out)
				loads <- model
			}
		}
	}()

	// One planner pass per queued cold model. The provider becomes plannable
	// once its challenge round-trip lands, so retry the trigger until the
	// load_model frame is observed (a reserved load dedups later triggers).
	triggerLoad := func(model string) *registry.QueuedRequest {
		t.Helper()
		req := &registry.QueuedRequest{RequestID: "q-" + model, Model: model,
			Pending: &registry.PendingRequest{RequestID: "q-" + model, Model: model}}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(10 * time.Second)
		for {
			reg.TriggerModelSwaps()
			select {
			case got := <-loads:
				if got != model {
					t.Fatalf("provider received load_model for %q, want %q", got, model)
				}
				return req
			case <-time.After(100 * time.Millisecond):
			}
			if time.Now().After(deadline) {
				t.Fatalf("planner never sent load_model for %q", model)
			}
		}
	}

	okReq := triggerLoad(okModel)
	packets := drainUntil(t, statsdFlusher{dd.Statsd}, collector, 5*time.Second, func(ps []string) bool {
		return hasMetricWith(ps, "model_load.result", "status:succeeded", "model:"+okModel)
	})
	if !hasMetricWith(packets, "model_load.result", "status:succeeded", "model:"+okModel) {
		t.Fatalf("no model_load.result{status:succeeded} after a successful load; packets=%v", packets)
	}
	if !hasMetricWith(packets, "model_load.sent", "planner:swap") {
		t.Fatalf("no model_load.sent{planner:swap} for the planner-issued load; packets=%v", packets)
	}
	if !hasMetricWith(packets, "model_load.duration_ms", "model:"+okModel) {
		t.Fatalf("no model_load.duration_ms sample for the successful load; packets=%v", packets)
	}

	// The successful load drained the waiter onto the provider (a real
	// scheduler reservation). Release it so the idle-only load picker can
	// plan the next load on the same box.
	select {
	case assigned := <-okReq.ResponseCh:
		if assigned == nil {
			t.Fatal("waiter for the loaded model was failed instead of assigned")
		}
		assigned.RemovePending(okReq.RequestID)
		reg.SetProviderIdle(assigned.ID)
	case <-time.After(5 * time.Second):
		t.Fatal("load success did not drain the queued waiter")
	}

	// The failing load: still counted as sent, terminal status failed.
	triggerLoad(failModel)
	packets = drainUntil(t, statsdFlusher{dd.Statsd}, collector, 5*time.Second, func(ps []string) bool {
		return hasMetricWith(ps, "model_load.result", "status:failed", "model:"+failModel)
	})
	if !hasMetricWith(packets, "model_load.result", "status:failed", "model:"+failModel) {
		t.Fatalf("no model_load.result{status:failed} after a failed load; packets=%v", packets)
	}
	if !hasMetricWith(packets, "model_load.sent", "planner:swap") {
		t.Fatalf("second planner-issued load was not counted as sent; packets=%v", packets)
	}
}

// TestSpillEventAttributesAttempt pins the retry attribution of the warm-pool
// demand feeders: attempt 0 is attempt:first, any later attempt attempt:retry,
// and the kind tag names the signal. Three misses on attempts 0,1,2 are three
// spill events of which two carry attempt:retry.
func TestSpillEventAttributesAttempt(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	srv.recordWarmPoolCapacityReject("spill-model", 0)
	for attempt := 0; attempt < 3; attempt++ {
		srv.recordWarmPoolTTFTMiss("spill-model", time.Second, attempt)
	}
	packets := drainUntil(t, statsdFlusher{dd.Statsd}, collector, 3*time.Second, func(ps []string) bool {
		return counterSum(ps, "warm_pool.spill_event") >= 4
	})
	if got := counterSum(packets, "warm_pool.spill_event"); got != 4 {
		t.Fatalf("spill events = %d, want 4; packets=%v", got, packets)
	}
	if got := counterSum(packets, "warm_pool.spill_event", "kind:capacity_reject", "attempt:first"); got != 1 {
		t.Fatalf("capacity_reject/first = %d, want 1", got)
	}
	if got := counterSum(packets, "warm_pool.spill_event", "kind:ttft_miss", "attempt:first"); got != 1 {
		t.Fatalf("ttft_miss/first = %d, want 1", got)
	}
	if got := counterSum(packets, "warm_pool.spill_event", "kind:ttft_miss", "attempt:retry"); got != 2 {
		t.Fatalf("ttft_miss/retry = %d, want 2 (attempts 1 and 2)", got)
	}
}
