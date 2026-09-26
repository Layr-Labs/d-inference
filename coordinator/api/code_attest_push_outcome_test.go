package api

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reportingCodeAttestor is a fake attestor that also describes each push, as
// the production APNsPushAttestor does.
type reportingCodeAttestor struct {
	fakeCodeAttestor
	result func() apns.PushResult
}

func (r *reportingCodeAttestor) SendCodeChallengeResult(ctx context.Context, deviceToken, env, pubKeyB64, nonceB64 string) (apns.PushResult, error) {
	return r.result(), r.SendCodeChallenge(ctx, deviceToken, env, pubKeyB64, nonceB64)
}

func codeAttestPushCount(srv *Server, label, value string) int64 {
	name := "code_attest_push_total"
	if label == "result" {
		name = "code_attest_push_reply_total"
	}
	return srv.metrics.Snapshot().Counters[metricKey(name, []MetricLabel{{label, value}})]
}

func TestCodeAttestPushOutcomeRecordedPerPushWithoutChangingTrust(t *testing.T) {
	for _, tc := range []struct {
		result apns.PushResult
		err    error
		want   string
	}{
		{apns.PushResult{StatusCode: 410, Reason: apns.ReasonUnregistered}, errors.New("apns: status 410"), "rejected_unregistered"},
		{apns.PushResult{StatusCode: 400, Reason: apns.ReasonBadDeviceToken}, errors.New("apns: status 400"), "rejected_bad_device_token"},
		{apns.PushResult{StatusCode: 429, Reason: apns.ReasonTooManyRequests}, errors.New("apns: 429"), "throttled"},
		{apns.PushResult{Transport: true}, errors.New("apns: send: EOF"), "transport_error"},
		{apns.PushResult{StatusCode: 200, APNsIDPresent: true}, nil, "sent_ok"},
	} {
		logger := quietLogger()
		srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
		kPub, _, _, sePub := providerKeyMaterial(t)
		provider := newCodeAttestProvider(kPub, sePub)
		srv.SetCodeAttestor(&reportingCodeAttestor{
			fakeCodeAttestor: fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return tc.err }},
			result:           func() apns.PushResult { return tc.result },
		})
		sent := srv.sendCodeIdentityChallenge(context.Background(), provider.ID, provider)
		if sent != (tc.err == nil) {
			t.Fatalf("%s: send result changed: %v", tc.want, sent)
		}
		if got := codeAttestPushCount(srv, "outcome", tc.want); got != 1 {
			t.Fatalf("%s: push outcome count %d", tc.want, got)
		}
		if provider.GetCodeAttested() {
			t.Fatalf("%s: a push outcome granted code identity", tc.want)
		}
	}
}

func TestCodeAttestPushOutcomeFallsBackForAttestorsWithoutResults(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	kPub, _, _, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	fail := true
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		if fail {
			return errors.New("send failed")
		}
		return nil
	}})
	srv.sendCodeIdentityChallenge(context.Background(), provider.ID, provider)
	fail = false
	srv.sendCodeIdentityChallenge(context.Background(), provider.ID, provider)
	if codeAttestPushCount(srv, "outcome", "transport_error") != 1 || codeAttestPushCount(srv, "outcome", "sent_ok") != 1 {
		t.Fatalf("fallback outcomes: %v", srv.metrics.Snapshot().Counters)
	}
}

// Three accepted pushes go unanswered, the fourth is answered: the loop
// records each re-push after an unanswered accepted push, and the verified
// reply as answered.
func TestCodeAttestPushReplyAnsweredAndUnanswered(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background())
	clock := newManualCodeAttestClock(srv.codeAttestThrottle)
	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	var pushes atomic.Int32
	srv.SetCodeAttestor(&reportingCodeAttestor{
		fakeCodeAttestor: fakeCodeAttestor{onSend: func(_, _, pubKey, nonce string) error {
			clock.advance(time.Second)
			if pushes.Add(1) <= 3 {
				return nil
			}
			return completeRoundTrip(t, srv, provider, provider.ID, kPriv, seKey, pubKey, nonce)
		}},
		result: func() apns.PushResult { return apns.PushResult{StatusCode: 200, APNsIDPresent: true} },
	})
	done := runCodeAttestLoopAsync(t.Context(), srv, provider)
	if !waitForCond(2*time.Second, func() bool { return pushes.Load() == 3 }) {
		t.Fatalf("fast pushes = %d", pushes.Load())
	}
	clock.advance(srv.codeAttestThrottle.slowRetryInterval)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("loop did not finish after the answered push")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("answered push did not attest")
	}
	if got := codeAttestPushCount(srv, "result", "unanswered"); got != 3 {
		t.Fatalf("unanswered = %d, want 3", got)
	}
	if got := codeAttestPushCount(srv, "result", "answered"); got != 1 {
		t.Fatalf("answered = %d, want 1", got)
	}
	if got := codeAttestPushCount(srv, "outcome", "sent_ok"); got != 4 {
		t.Fatalf("sent_ok = %d, want 4", got)
	}
}

// An accepted push left unanswered when the provider reconnects is counted by
// the replacement connection's loop at its next push, not lost with the old
// loop's state.
func TestCodeAttestUnansweredPushSurvivesReconnect(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background())
	clock := newManualCodeAttestClock(srv.codeAttestThrottle)
	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	var pushes atomic.Int32
	var answer atomic.Bool
	srv.SetCodeAttestor(&reportingCodeAttestor{
		fakeCodeAttestor: fakeCodeAttestor{onSend: func(_, _, pubKey, nonce string) error {
			clock.advance(time.Second)
			pushes.Add(1)
			if !answer.Load() {
				return nil
			}
			return completeRoundTrip(t, srv, provider, provider.ID, kPriv, seKey, pubKey, nonce)
		}},
		result: func() apns.PushResult { return apns.PushResult{StatusCode: 200, APNsIDPresent: true} },
	})
	firstConnection, disconnect := context.WithCancel(t.Context())
	done := runCodeAttestLoopAsync(firstConnection, srv, provider)
	if !waitForCond(2*time.Second, func() bool { return pushes.Load() == 3 }) {
		t.Fatalf("first connection pushes = %d", pushes.Load())
	}
	disconnect()
	<-done
	// Retries count the earlier pushes; disconnect finalizes the last one.
	if got := codeAttestPushCount(srv, "result", "unanswered"); got != 3 {
		t.Fatalf("unanswered before the reconnect = %d, want 3", got)
	}
	answer.Store(true)
	select {
	case <-runCodeAttestLoopAsync(t.Context(), srv, provider):
	case <-time.After(2 * time.Second):
		t.Fatal("reconnected loop did not finish")
	}
	if got := codeAttestPushCount(srv, "result", "unanswered"); got != 3 {
		t.Fatalf("unanswered = %d, want 3 (the first connection's last push)", got)
	}
	if got := codeAttestPushCount(srv, "result", "answered"); got != 1 {
		t.Fatalf("answered = %d, want 1", got)
	}
}

// A terminating loop cannot count a newer loop's pushes or count its own twice.
// Finalizing diagnostics must preserve the nonce for a late verified reply.
func TestCodeAttestFinalizationIsGenerationScopedAndPreservesLateReplies(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	throttle := srv.codeAttestThrottle
	throttle.recordChallengeForIdentity("device", "old", "token", "node")
	throttle.markChallengeAccepted("device", "old", 1)
	throttle.recordChallengeForIdentity("device", "new", "token", "node")
	throttle.markChallengeAccepted("device", "new", 2)
	throttle.recordChallengeForIdentity("device", "rejected", "token", "node")
	srv.recordUnansweredCodeAttestPushes("provider", "device", 1)
	srv.recordUnansweredCodeAttestPushes("provider", "device", 1)
	if got := codeAttestPushCount(srv, "result", "unanswered"); got != 1 {
		t.Fatalf("unanswered = %d", got)
	}
	if !throttle.consumeChallengeForIdentity("device", "old", "token", "node") {
		t.Fatal("finalization invalidated late proof")
	}
	if !throttle.consumeChallengeForIdentity("device", "new", "token", "node") {
		t.Fatal("new loop challenge lost")
	}
	srv.recordUnansweredCodeAttestPushes("provider", "device", 2)
	srv.recordUnansweredCodeAttestPushes("provider", "device")
	if got := codeAttestPushCount(srv, "result", "unanswered"); got != 1 {
		t.Fatalf("answered/rejected push counted: %d", got)
	}
}

func TestCodeAttestLoopFinalizesWithoutAnotherPush(t *testing.T) {
	for _, ending := range []string{"disconnect", "hard_untrust", "other_proof"} {
		t.Run(ending, func(t *testing.T) {
			logger := quietLogger()
			srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
			srv.codeAttestThrottle.retrySpacing = time.Millisecond
			srv.codeAttestThrottle.retryJitter = 0
			kPub, _, _, sePub := providerKeyMaterial(t)
			provider := newCodeAttestProvider(kPub, sePub)
			srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { return nil }})
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			done := runCodeAttestLoopAsync(ctx, srv, provider)
			if !waitForCond(2*time.Second, func() bool { return codeAttestPushCount(srv, "outcome", "sent_ok") == 1 }) {
				t.Fatal("push was not accepted")
			}
			switch ending {
			case "disconnect":
				cancel()
			case "hard_untrust":
				provider.Mu().Lock()
				provider.Status = registry.StatusUntrusted
				provider.Mu().Unlock()
			case "other_proof":
				provider.SetCodeAttested(true)
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("loop did not terminate")
			}
			if got := codeAttestPushCount(srv, "result", "unanswered"); got != 1 {
				t.Fatalf("unanswered = %d", got)
			}
			if got := codeAttestPushCount(srv, "result", "answered"); got != 0 {
				t.Fatalf("answered = %d", got)
			}
		})
	}
}
