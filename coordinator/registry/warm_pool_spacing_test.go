package registry

// Tests for the trigger-driven tick spacing in warmPoolController.run
// (warmPoolTriggerSpacing): a burst of RequestWarmPoolTrigger calls inside
// one window costs one immediate tick plus one trailing tick, a trigger after
// the window ticks immediately, the baseline ticker is untouched, and a
// cancelled context stops the goroutine with a trailing timer pending.
//
// These drive the real run() goroutine with real timers and assert tick
// COUNTS with generous margins rather than timings, so they hold on a loaded
// machine.

import (
	"context"
	"testing"
	"time"
)

// spacingTestController returns a controller whose ticks plan but never send
// (MaxLoadsPerTick 0 → observe-only planning) on a registry with one queued
// pressure signal, so every tick does real work.
func spacingTestController(t *testing.T, interval time.Duration) (*Registry, *warmPoolController) {
	t.Helper()
	reg := New(testLogger())
	model := "spacing-model"
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.Interval = interval
	cfg.MaxLoadsPerTick = 0
	reg.ConfigureWarmPool(cfg)
	reg.RecordWarmPoolCapacityReject(model)
	return reg, reg.warmPool
}

func awaitTicks(t *testing.T, c *warmPoolController, want int64, within time.Duration, what string) {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		if got := c.ticks.Load(); got >= want {
			if got > want {
				t.Fatalf("%s: %d ticks, want exactly %d", what, got, want)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: %d ticks after %v, want %d", what, c.ticks.Load(), within, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestEffectiveTriggerSpacing(t *testing.T) {
	if got := effectiveTriggerSpacing(30 * time.Second); got != warmPoolTriggerSpacing {
		t.Fatalf("prod interval: spacing = %v, want %v", got, warmPoolTriggerSpacing)
	}
	if got := effectiveTriggerSpacing(4 * time.Second); got != warmPoolTriggerSpacing {
		t.Fatalf("4 s interval: spacing = %v, want %v", got, warmPoolTriggerSpacing)
	}
	if got := effectiveTriggerSpacing(time.Second); got != 250*time.Millisecond {
		t.Fatalf("1 s interval: spacing = %v, want 250ms (Interval/4)", got)
	}
}

// TestWarmPoolTriggerBurstIsSpacedWithTrailingTick: 200 triggers inside one
// spacing window run exactly one tick at once and exactly one trailing tick
// at the end of the window; a trigger after the window ticks immediately.
// Before the change the count was bounded only by tick duration.
func TestWarmPoolTriggerBurstIsSpacedWithTrailingTick(t *testing.T) {
	// Interval 2 s → spacing 500 ms; the whole test stays under the baseline
	// interval so the ticker cannot contribute a tick.
	reg, c := spacingTestController(t, 2*time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		c.run(ctx)
	}()

	start := time.Now()
	for i := 0; i < 200; i++ {
		reg.RequestWarmPoolTrigger()
		if i%20 == 0 {
			time.Sleep(5 * time.Millisecond)
		}
	}
	burst := time.Since(start)
	if burst >= 400*time.Millisecond {
		t.Skipf("burst took %v on this machine; the window cannot be asserted", burst)
	}
	// One immediate tick during the burst, then the trailing tick once the
	// window (500 ms after the first tick) elapses — and nothing more.
	awaitTicks(t, c, 1, 200*time.Millisecond, "burst")
	time.Sleep(100 * time.Millisecond)
	if got := c.ticks.Load(); got != 1 {
		t.Fatalf("inside the window: %d ticks, want 1 (trailing tick armed, not run)", got)
	}
	awaitTicks(t, c, 2, time.Second, "trailing tick")
	time.Sleep(100 * time.Millisecond)
	if got := c.ticks.Load(); got != 2 {
		t.Fatalf("after the trailing tick: %d ticks, want 2", got)
	}

	// The trailing tick opened a new window; a trigger after it elapses runs
	// at once.
	time.Sleep(600 * time.Millisecond)
	reg.RequestWarmPoolTrigger()
	awaitTicks(t, c, 3, 300*time.Millisecond, "trigger after the window")

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("run loop did not stop on context cancel")
	}
}

// TestWarmPoolBaselineTickerUnaffectedBySpacing: with no triggers the
// baseline ticker still fires every Interval.
func TestWarmPoolBaselineTickerUnaffectedBySpacing(t *testing.T) {
	_, c := spacingTestController(t, 150*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		c.run(ctx)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for c.ticks.Load() < 3 {
		if time.Now().After(deadline) {
			t.Fatalf("baseline ticker produced %d ticks in 3 s at a 150 ms interval, want >= 3", c.ticks.Load())
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
}

// TestWarmPoolRunStopsWithTrailingTimerPending: a context cancel while a
// trailing tick is armed stops the goroutine and the armed tick never runs
// (no leaked timer callback touching the controller after shutdown; -race).
func TestWarmPoolRunStopsWithTrailingTimerPending(t *testing.T) {
	reg, c := spacingTestController(t, 2*time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		c.run(ctx)
	}()
	reg.RequestWarmPoolTrigger()
	awaitTicks(t, c, 1, time.Second, "first trigger")
	// Inside the window: arms the trailing tick.
	reg.RequestWarmPoolTrigger()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("run loop did not stop with a trailing timer pending")
	}
	time.Sleep(700 * time.Millisecond) // past the 500 ms window
	if got := c.ticks.Load(); got != 1 {
		t.Fatalf("armed trailing tick ran after shutdown: %d ticks, want 1", got)
	}
}

// TestTriggerWarmPoolStaysImmediateUnderSpacing: the administrative/test
// entry point bypasses the spacing entirely.
func TestTriggerWarmPoolStaysImmediateUnderSpacing(t *testing.T) {
	reg, c := spacingTestController(t, 2*time.Second)
	cfg := c.config
	cfg.MaxLoadsPerTick = 1
	reg.ConfigureWarmPool(cfg)
	captureWarmPoolLoads(reg)
	for i := 0; i < 3; i++ {
		if snaps := reg.TriggerWarmPool(); len(snaps) == 0 {
			t.Fatalf("TriggerWarmPool %d returned no snapshots", i)
		}
	}
	if got := c.ticks.Load(); got != 3 {
		t.Fatalf("TriggerWarmPool ticked %d times, want 3 (never spaced)", got)
	}
}
