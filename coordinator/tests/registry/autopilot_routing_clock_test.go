package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	autopilotClockSession  = "clock-session"
	autopilotClockModel    = "clock-ordinary-model"
	autopilotClockObserver = "clock-observer-model"
	autopilotClockRevision = "clock-revision"
)

func autopilotClockConsent() *protocol.ModelAutopilotState {
	return &protocol.ModelAutopilotState{
		Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Active: true,
		SessionID: autopilotClockSession, Revision: autopilotClockRevision,
		SelectedModels: []string{autopilotClockObserver},
	}
}

// autopilotClockState advertises one ordinary model and one observer-only model.
func autopilotClockState(consent *protocol.ModelAutopilotState) *autopilotstate.State {
	state := autopilotstate.New(nil)
	state.RegisterInventory(
		[]protocol.ModelInfo{{ID: autopilotClockModel}},
		[]protocol.ModelInfo{{ID: autopilotClockObserver, WeightHash: "observer-weights"}},
		consent,
	)
	return state
}

// The scheduler runs these checks for every candidate of every request. Only a
// provider holding a matching control grant has an expiry to compare, so every
// other provider must be decided without reading the clock.
func TestAutopilotRoutingChecksSkipClockWithoutMatchingGrant(t *testing.T) {
	consent := autopilotClockConsent()
	granted := autopilotClockState(consent)
	granted.AcceptControl(consent, protocol.ModelAutopilotControl{Revision: autopilotClockRevision, ExpiresAtMS: time.Now().Add(time.Hour).UnixMilli()})
	changedSelection := autopilotClockConsent()
	changedSelection.Revision = "clock-revision-changed"
	for name, tc := range map[string]struct {
		state   *autopilotstate.State
		consent *protocol.ModelAutopilotState
	}{
		"no autopilot state":             {state: autopilotstate.New(nil)},
		"nil provider state":             {consent: consent},
		"consent without grant":          {state: autopilotClockState(consent), consent: consent},
		"observer model, no consent":     {state: autopilotClockState(consent)},
		"grant for a previous selection": {state: granted, consent: changedSelection},
	} {
		t.Run(name, func(t *testing.T) {
			clock := func() time.Time {
				t.Fatal("routing check read the clock without a matching grant")
				return time.Time{}
			}
			for _, model := range []string{autopilotClockModel, autopilotClockObserver} {
				ordinary := tc.state.OrdinaryAllowed(tc.consent, autopilotClockSession, model, clock)
				observerOnly := tc.state != nil && tc.state.ObserverOnly(model)
				if ordinary == observerOnly {
					t.Fatalf("%s: ordinary=%t observer-only=%t without a matching grant", model, ordinary, observerOnly)
				}
				if blocked := tc.state.RoutingBlocked(tc.consent, autopilotClockSession, model, nil, clock); blocked != observerOnly {
					t.Fatalf("%s: routing blocked=%t, want %t", model, blocked, observerOnly)
				}
			}
			if tc.state.LegacyChangesBlocked(tc.consent, autopilotClockSession, clock) {
				t.Fatal("legacy model changes blocked without a matching grant or pause")
			}
		})
	}
}

// With a matching grant the same checks still compare the lease expiry, so a
// lapsed grant stops managing the provider at exactly its expiry instant.
func TestAutopilotRoutingChecksHonorGrantExpiry(t *testing.T) {
	consent := autopilotClockConsent()
	state := autopilotClockState(consent)
	expiry := time.UnixMilli(1_800_000_000_000)
	state.AcceptControl(consent, protocol.ModelAutopilotControl{Revision: autopilotClockRevision, ExpiresAtMS: expiry.UnixMilli()})

	for name, tc := range map[string]struct {
		now     time.Time
		managed bool
	}{
		"before expiry": {now: expiry.Add(-time.Millisecond), managed: true},
		"at expiry":     {now: expiry},
	} {
		t.Run(name, func(t *testing.T) {
			reads := 0
			clock := func() time.Time { reads++; return tc.now }
			if got := state.LegacyChangesBlocked(consent, autopilotClockSession, clock); got != tc.managed {
				t.Fatalf("legacy changes blocked=%t, want %t", got, tc.managed)
			}
			if got := state.OrdinaryAllowed(consent, autopilotClockSession, autopilotClockObserver, clock); got != tc.managed {
				t.Fatalf("observer model allowed=%t, want %t", got, tc.managed)
			}
			// A managed provider without a loaded slot for the model is fenced.
			if got := state.RoutingBlocked(consent, autopilotClockSession, autopilotClockModel, nil, clock); got != tc.managed {
				t.Fatalf("ordinary model routing blocked=%t, want %t", got, tc.managed)
			}
			if reads == 0 {
				t.Fatal("a matching grant was decided without comparing its expiry")
			}
		})
	}
}
