package api

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// manualCodeAttestClock drives the throttle's budget and slow-cadence clock
// from the test goroutine while the loop polls on real (1ms) timers.
type manualCodeAttestClock struct{ nanos atomic.Int64 }

func newManualCodeAttestClock(th *codeAttestThrottle) *manualCodeAttestClock {
	c := &manualCodeAttestClock{}
	c.nanos.Store(time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC).UnixNano())
	th.now = c.now
	return c
}

func (c *manualCodeAttestClock) now() time.Time { return time.Unix(0, c.nanos.Load()) }

func (c *manualCodeAttestClock) advance(d time.Duration) { c.nanos.Add(int64(d)) }

func codeAttestOutcomeCount(srv *Server, outcome string) int64 {
	return srv.metrics.Snapshot().Counters[metricKey(
		"code_attest_total", []MetricLabel{{"outcome", outcome}},
	)]
}

func runCodeAttestLoopAsync(ctx context.Context, srv *Server, p *registry.Provider) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.codeAttestLoop(ctx, p.ID, p)
	}()
	return done
}

// A long-lived connection whose first maxAttempts pushes go unanswered (the
// post-release reconnect burst) is pushed again after the slow interval and
// becomes code-attested when it finally answers, with no reconnect.
func TestCodeAttestSlowRetryRecoversLongLivedConnection(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background()) // durable budget on the admission path
	clock := newManualCodeAttestClock(srv.codeAttestThrottle)

	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	var pushes atomic.Int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKey, nonce string) error {
		clock.advance(time.Second) // each fast push clears the 1ms budget
		if pushes.Add(1) <= 3 {
			return nil // delivered, never answered
		}
		return completeRoundTrip(t, srv, provider, provider.ID, kPriv, seKey, pubKey, nonce)
	}})

	done := runCodeAttestLoopAsync(t.Context(), srv, provider)
	if !waitForCond(2*time.Second, func() bool { return pushes.Load() == 3 }) {
		t.Fatalf("fast pushes = %d, want 3", pushes.Load())
	}
	time.Sleep(50 * time.Millisecond) // many polls; slow interval not yet elapsed
	if got := pushes.Load(); got != 3 || provider.GetCodeAttested() {
		t.Fatalf("pushed before the slow interval: pushes=%d attested=%v", got, provider.GetCodeAttested())
	}
	select {
	case <-done:
		t.Fatal("loop gave up on a live unattested connection after maxAttempts")
	default:
	}

	clock.advance(srv.codeAttestThrottle.slowRetryInterval)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("slow retry did not complete the proof")
	}
	if !provider.GetCodeAttested() || pushes.Load() != 4 {
		t.Fatalf("attested=%v pushes=%d, want attested after exactly 4 pushes",
			provider.GetCodeAttested(), pushes.Load())
	}
	if codeAttestOutcomeCount(srv, "slow_retry") != 1 ||
		codeAttestOutcomeCount(srv, "max_attempts") != 1 {
		t.Fatalf("slow_retry=%d max_attempts=%d, want 1/1",
			codeAttestOutcomeCount(srv, "slow_retry"), codeAttestOutcomeCount(srv, "max_attempts"))
	}
}

// The slow cadence is only local pacing: even with a zero slow interval the
// per-device push budget still admits at most one push per cooldown.
func TestCodeAttestSlowRetryStillHonorsPushBudget(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	fastBudgets(srv)
	srv.SeedCodeAttestCache(context.Background())
	clock := newManualCodeAttestClock(srv.codeAttestThrottle)
	srv.codeAttestThrottle.backgroundPushCooldown = 20 * time.Minute
	srv.codeAttestThrottle.maxAttempts = 1
	srv.codeAttestThrottle.slowRetryInterval = 0

	kPub, _, _, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	var pushes atomic.Int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		pushes.Add(1)
		return nil
	}})

	done := runCodeAttestLoopAsync(t.Context(), srv, provider)
	if !waitForCond(time.Second, func() bool { return pushes.Load() == 1 }) {
		t.Fatal("first push not sent")
	}
	time.Sleep(100 * time.Millisecond) // ~100 slow-mode polls inside one cooldown
	if got := pushes.Load(); got != 1 {
		t.Fatalf("slow retry bypassed the push budget: pushes=%d", got)
	}
	clock.advance(20 * time.Minute)
	if !waitForCond(time.Second, func() bool { return pushes.Load() == 2 }) {
		t.Fatalf("slow retry did not push after the budget elapsed: pushes=%d", pushes.Load())
	}
	time.Sleep(50 * time.Millisecond)
	if got := pushes.Load(); got != 2 {
		t.Fatalf("slow retry pushed more than once per cooldown: pushes=%d", got)
	}
	select {
	case <-done:
		t.Fatal("loop exited while the connection was alive and unattested")
	default:
	}
}

// While waiting on the slow cadence the loop still stops on disconnect, hard
// untrust, and loop-generation change, without spending another push.
func TestCodeAttestSlowRetryStopsOnDisconnectUntrustOrSupersede(t *testing.T) {
	for _, tc := range []struct {
		name string
		stop func(cancel context.CancelFunc, srv *Server, p *registry.Provider, seKey string)
	}{
		{"disconnect", func(cancel context.CancelFunc, _ *Server, _ *registry.Provider, _ string) { cancel() }},
		{"hard_untrust", func(_ context.CancelFunc, _ *Server, p *registry.Provider, _ string) {
			p.Mu().Lock()
			p.Status = registry.StatusUntrusted // not recoverable
			p.Mu().Unlock()
		}},
		{"superseded_loop", func(_ context.CancelFunc, srv *Server, _ *registry.Provider, seKey string) {
			srv.codeAttestThrottle.beginLoop(seKey)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logger := quietLogger()
			srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
			fastBudgets(srv)
			srv.codeAttestThrottle.slowRetryInterval = time.Hour
			kPub, _, _, sePub := providerKeyMaterial(t)
			provider := newCodeAttestProvider(kPub, sePub)
			var pushes atomic.Int32
			srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
				pushes.Add(1)
				return nil
			}})
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			done := runCodeAttestLoopAsync(ctx, srv, provider)
			if !waitForCond(2*time.Second, func() bool { return pushes.Load() == 3 }) {
				t.Fatalf("fast pushes = %d, want 3", pushes.Load())
			}
			tc.stop(cancel, srv, provider, sePub)
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("slow-cadence loop did not stop")
			}
			if got := pushes.Load(); got != 3 || provider.GetCodeAttested() {
				t.Fatalf("pushes=%d attested=%v after stop", got, provider.GetCodeAttested())
			}
		})
	}
}

// A coordinator redeploy recovers a provider that never answered the previous
// instance's pushes without any provider action: the reconnected connection's
// fresh loop waits out the durable per-device budget left by the old instance
// (no post-deploy push storm), then pushes and attests.
func TestCodeAttestRedeployRecoversUnansweredDeviceWithinDurableBudget(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	oldSrv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	oldSrv.SeedCodeAttestCache(context.Background())
	oldSrv.codeAttestThrottle.retrySpacing = time.Millisecond
	oldSrv.codeAttestThrottle.retryJitter = 0
	clock := newManualCodeAttestClock(oldSrv.codeAttestThrottle)

	kPub, kPriv, seKey, sePub := providerKeyMaterial(t)
	var oldPushes atomic.Int32
	oldSrv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		oldPushes.Add(1)
		return nil
	}})
	oldCtx, stopOld := context.WithCancel(t.Context())
	oldDone := runCodeAttestLoopAsync(oldCtx, oldSrv, newCodeAttestProvider(kPub, sePub))
	if !waitForCond(time.Second, func() bool { return oldPushes.Load() == 1 }) {
		t.Fatal("old instance did not push")
	}
	stopOld() // coordinator shutdown drops the connection
	<-oldDone

	newSrv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	newSrv.codeAttestThrottle.now = clock.now
	newSrv.codeAttestThrottle.retrySpacing = time.Millisecond
	newSrv.codeAttestThrottle.retryJitter = 0
	newSrv.SeedCodeAttestCache(context.Background())
	reconnected := newCodeAttestProvider(kPub, sePub)
	var newPushes atomic.Int32
	newSrv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKey, nonce string) error {
		newPushes.Add(1)
		return completeRoundTrip(t, newSrv, reconnected, reconnected.ID, kPriv, seKey, pubKey, nonce)
	}})
	done := runCodeAttestLoopAsync(t.Context(), newSrv, reconnected)
	time.Sleep(50 * time.Millisecond)
	if got := newPushes.Load(); got != 0 {
		t.Fatalf("redeployed instance ignored the durable budget: pushes=%d", got)
	}
	clock.advance(newSrv.codeAttestThrottle.backgroundPushCooldown)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("redeployed loop did not recover the device")
	}
	if !reconnected.GetCodeAttested() || newPushes.Load() != 1 {
		t.Fatalf("attested=%v pushes=%d", reconnected.GetCodeAttested(), newPushes.Load())
	}
}
