package api

// attestation.challenge_rtt_ms: sendChallenge stamped sentAt on every
// pending challenge but never emitted the delta, so challenge latency (and
// the head-of-line wedge behind a cold model load) was invisible in prod.
// One histogram sample per challenge outcome, through the real DogStatsD
// client and the real /ws/provider handshake.

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// awaitChallengeRTTSample polls the collector until a challenge_rtt_ms sample
// with the given outcome arrives, returning the packet.
func awaitChallengeRTTSample(t *testing.T, collector *udpCollector, dd *datadogFlusher, outcome string) string {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	var seen []string
	for time.Now().Before(deadline) {
		seen = append(seen, findMetrics(dd.packets(collector), "attestation.challenge_rtt_ms")...)
		for _, p := range seen {
			if strings.Contains(p, "outcome:"+outcome) {
				return p
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("no attestation.challenge_rtt_ms sample with outcome:%s; saw %v", outcome, seen)
	return ""
}

func TestChallengeRTTHistogramOnSuccess(t *testing.T) {
	srv, _, _, ts := setupTestServer(t)
	defer ts.Close()
	collector, dd := attachTestDD(t, srv)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: "rtt-model", ModelType: "chat", Quantization: "4bit"}}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	// Answer the registration-time challenge; the coordinator verifies it on
	// the challenge goroutine and emits the sample.
	waitForChallenge(t, ctx, conn, pubKey)

	pk := awaitChallengeRTTSample(t, collector, dd, "ok")
	if v := metricValue(t, pk); v <= 0 {
		t.Fatalf("challenge_rtt_ms = %v, want a positive round trip", v)
	}
	if !strings.Contains(pk, "provider_version:") {
		t.Fatalf("sample lacks the provider_version tag: %s", pk)
	}
	if strings.Contains(pk, "provider_id:") {
		t.Fatalf("sample carries a provider id: %s", pk)
	}
}

func TestChallengeRTTHistogramOnTimeout(t *testing.T) {
	srv, _, _, ts := setupTestServer(t)
	defer ts.Close()
	srv.challengeResponseTimeout = 150 * time.Millisecond
	collector, dd := attachTestDD(t, srv)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pubKey := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: "rtt-timeout-model", ModelType: "chat", Quantization: "4bit"}}, pubKey)
	defer conn.CloseNow()
	// A provider that reads but never answers its challenges.
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	pk := awaitChallengeRTTSample(t, collector, dd, "timeout")
	if v := metricValue(t, pk); v < 100 {
		t.Fatalf("timeout sample = %v ms, want >= the 150 ms response budget (minus scheduling slack)", v)
	}
}
