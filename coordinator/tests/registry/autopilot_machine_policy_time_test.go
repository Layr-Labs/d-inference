package registry_test

import (
	"context"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type autopilotClockStore struct {
	*memory.MemoryStore
	policyDelay      time.Duration
	firstIntentDelay time.Duration
}

func (s *autopilotClockStore) LiveMachineAutopilotSettings(ctx context.Context) ([]store.MachineAutopilotSetting, error) {
	if err := autopilotStoreDelay(ctx, s.policyDelay); err != nil {
		return nil, err
	}
	return s.MemoryStore.LiveMachineAutopilotSettings(ctx)
}

func (s *autopilotClockStore) RecordAutopilot(ctx context.Context, records []store.AutopilotRecord) error {
	for _, record := range records {
		if record.Phase == "reserved" && s.firstIntentDelay > 0 {
			delay := s.firstIntentDelay
			s.firstIntentDelay = 0
			if err := autopilotStoreDelay(ctx, delay); err != nil {
				return err
			}
			break
		}
	}
	return s.MemoryStore.RecordAutopilot(ctx, records)
}

func autopilotStoreDelay(ctx context.Context, delay time.Duration) error {
	if delay == 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return ctx.Err()
	case <-ctx.Done():
		return ctx.Err()
	}
}

func installAutopilotClockStore(t *testing.T, r *autopilotFixture) *autopilotClockStore {
	t.Helper()
	backend, ok := store.As[*memory.MemoryStore](r.store)
	if !ok {
		t.Fatal("clock fixture requires the real memory store")
	}
	s := &autopilotClockStore{MemoryStore: backend}
	r.SetStore(s)
	return s
}

func TestAutopilotTickRechecksCapacityAgeAfterMachinePolicyRead(t *testing.T) {
	for _, tc := range []struct {
		name string
		age  time.Duration
		want int
	}{
		{"still fresh", 28 * time.Second, 1},
		{"exact freshness boundary", 28500 * time.Millisecond, 1},
		{"stale after read", 29 * time.Second, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var commands []protocol.ModelAutopilotMessage
				r, c, sampledAt := newAutopilotControllerTest(t, false, func(d *production.Dependencies) {
					d.AutopilotSender = func(_ string, command protocol.ModelAutopilotMessage) error {
						commands = append(commands, command)
						return nil
					}
				})
				delayed := installAutopilotClockStore(t, r)
				p := autopilotControllerProvider(t, r, "provider", sampledAt)
				autopilotControllerPlan(t, r, c, sampledAt)
				time.Sleep(tc.age)
				delayed.policyDelay = 1500 * time.Millisecond
				started := time.Now()
				summary := c.Tick(started)
				if elapsed := time.Since(started); elapsed != delayed.policyDelay {
					t.Fatalf("policy read did not complete after the expected successful delay: %v", elapsed)
				}
				if summary.LiveCohort != 1 || summary.LiveActive != 1 || !autopilotMachineControlActive(r, p) {
					t.Fatalf("unchanged successful policy read revoked the fixture's acknowledged lease: %+v", summary)
				}
				p.Mu().Lock()
				_, owned := r.states[p.ID].PrepareDelivery()
				p.Mu().Unlock()
				if summary.Issued != tc.want || len(commands) != tc.want || owned != (tc.want != 0) {
					t.Fatalf("capacity age advanced from %v to %v during policy IO: issued=%d sent=%d owned=%v want=%d", tc.age, time.Since(sampledAt), summary.Issued, len(commands), owned, tc.want)
				}
				if tc.want == 0 && summary.Excluded["stale_or_private"] != 1 {
					t.Fatalf("expired sample was not rejected by capacity freshness: %+v", summary)
				}
			})
		})
	}
}

func TestAutopilotTickCapacityClockHonorsBufferedAndFutureTimes(t *testing.T) {
	for _, tc := range []struct {
		name   string
		age    time.Duration
		offset time.Duration
		want   int
	}{
		{"buffered still fresh", 26 * time.Second, -5 * time.Second, 1},
		{"buffered stale", 31 * time.Second, -5 * time.Second, 0},
		{"future exact freshness boundary", 28 * time.Second, 2 * time.Second, 1},
		{"future stale", 29 * time.Second, 2 * time.Second, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				sent := 0
				r, c, sampledAt := newAutopilotControllerTest(t, false, func(d *production.Dependencies) {
					d.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
				})
				p := autopilotControllerProvider(t, r, "provider", sampledAt)
				autopilotControllerPlan(t, r, c, sampledAt)
				time.Sleep(tc.age)
				summary := c.Tick(time.Now().Add(tc.offset))
				p.Mu().Lock()
				_, owned := r.states[p.ID].PrepareDelivery()
				p.Mu().Unlock()
				if summary.Issued != tc.want || sent != tc.want || owned != (tc.want != 0) {
					t.Fatalf("actual sample age=%v tick offset=%v: issued=%d sent=%d owned=%v want=%d", tc.age, tc.offset, summary.Issued, sent, owned, tc.want)
				}
				if summary.LiveActive != 1 || !autopilotMachineControlActive(r, p) {
					t.Fatal("clock regression was masked by revoking the fixture's live acknowledgement")
				}
			})
		})
	}
}

func TestAutopilotTickRechecksCapacityBetweenDurableDeliveries(t *testing.T) {
	for _, tc := range []struct {
		name  string
		age   time.Duration
		delay time.Duration
		want  int
	}{
		{"two actions without delay", 29 * time.Second, 0, 2},
		{"second still fresh", 28 * time.Second, 1500 * time.Millisecond, 2},
		{"second at freshness boundary", 28500 * time.Millisecond, 1500 * time.Millisecond, 2},
		{"second stale after first intent", 29 * time.Second, 1500 * time.Millisecond, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var sentTo []string
				r, c, sampledAt := newAutopilotControllerTest(t, false, func(d *production.Dependencies) {
					d.AutopilotSender = func(id string, _ protocol.ModelAutopilotMessage) error {
						sentTo = append(sentTo, id)
						return nil
					}
				})
				delayed := installAutopilotClockStore(t, r)
				delayed.firstIntentDelay = tc.delay
				warm := testWarmPoolConfig()
				warm.MinWarmByModel = map[string]int{autopilotTestTarget: 2}
				r.ConfigureWarmPool(warm)
				providers := []*production.Provider{
					autopilotControllerProvider(t, r, "first", sampledAt),
					autopilotControllerProvider(t, r, "second", sampledAt),
				}
				// A floor-only plan stops once one future load exists. Sustained
				// demand keeps the second recipient useful after the first reservation.
				for i := range 1000 {
					arrival := sampledAt.Add(-time.Minute + time.Duration(i%3)*10*time.Second)
					r.demand.Record(autopilot.DemandSample{Model: autopilotTestTarget, ReceivedAt: arrival, PromptTokens: 32, RequestedMaxTokens: 64}, sampledAt, r.cfg.DemandWindow)
				}
				autopilotControllerPlan(t, r, c, sampledAt)
				time.Sleep(tc.age)
				started := time.Now()
				summary := c.Tick(started)
				if elapsed := time.Since(started); elapsed != tc.delay {
					t.Fatalf("first durable intent did not exercise the requested IO delay: %v want=%v", elapsed, tc.delay)
				}
				owners := 0
				for _, p := range providers {
					p.Mu().Lock()
					_, owned := r.states[p.ID].PrepareDelivery()
					p.Mu().Unlock()
					if owned {
						owners++
					}
					if !autopilotMachineControlActive(r, p) {
						t.Fatal("unchanged live lease was revoked instead of rechecking sample age")
					}
				}
				if summary.Issued != tc.want || len(sentTo) != tc.want || owners != tc.want {
					t.Fatalf("capacity age advanced from %v to %v during the first delivery: issued=%d recipients=%v owners=%d want=%d", tc.age, time.Since(sampledAt), summary.Issued, sentTo, owners, tc.want)
				}
			})
		})
	}
}
