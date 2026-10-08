package provider_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestAutopilotConsentCaptureDelayedInventoryAndChallengeRetry(t *testing.T) {
	for _, response := range []string{protocol.TypeAttestationResponse, protocol.TypeCodeAttestationResponse} {
		t.Run(response, func(t *testing.T) {
			inventoryGate, tokenGate := make(chan struct{}), make(chan struct{})
			releaseInventory := sync.OnceFunc(func() { close(inventoryGate) })
			releaseToken := sync.OnceFunc(func() { close(tokenGate) })
			st := &consentCaptureStore{inventoryGate: inventoryGate, tokenGate: tokenGate, tokenEntered: make(chan struct{}, 1)}
			f := newConsentSocket(t, st)
			t.Cleanup(releaseInventory)
			t.Cleanup(releaseToken)
			publicKey := testkit.PublicKeyB64()
			before := time.Now().UTC()
			f.write(t, map[string]any{
				"type": protocol.TypeRegister, "auth_token": consentCaptureToken,
				"public_key": publicKey, "attestation": testkit.CreateAttestationJSON(t, publicKey),
				"model_autopilot": savedConsent(true), "first_opt_in_at": "1999-01-01T00:00:00Z",
			})
			select {
			case <-st.tokenEntered:
			case <-f.ctx.Done():
				t.Fatal("registration did not reach authentication")
			}
			authReleasedAt := time.Now().UTC()
			releaseToken()
			f.sync(t)
			calls := st.snapshot()
			if len(calls) != 1 || !errors.Is(calls[0].err, earningsfloor.ErrIdentity) {
				t.Fatalf("initial unbound declaration was not journaled: %+v", calls)
			}
			first := calls[0].consent
			if first.At.Before(before) || !first.At.Before(authReleasedAt) || first.At.Location() != time.UTC {
				t.Fatalf("receipt timestamp came from client or post-authentication work: %v, before=%v auth=%v", first.At, before, authReleasedAt)
			}
			if !first.OptedIn || !first.Supported || first.AccountID != consentCaptureAccount || len(f.enrollments(t)) != 0 {
				t.Fatalf("unbound consent became financial enrollment or lost authentication: %+v", first)
			}
			releaseInventory()
			select {
			case observation := <-st.observed:
				if observation.SessionID != first.SessionID || observation.SEKey == "" || observation.AccountID != consentCaptureAccount {
					t.Fatalf("real registration did not bind authenticated inventory: %+v", observation)
				}
			case <-f.ctx.Done():
				t.Fatal("asynchronous inventory never completed")
			}
			// A response retries already accepted consent; it must not invent
			// either a new receive instant or a new declaration.
			f.write(t, map[string]any{"type": response})
			f.sync(t)
			calls = st.snapshot()
			if len(calls) != 2 || calls[1].err != nil || calls[1].consent != first {
				t.Fatalf("challenge path did not retry the original declaration: %+v", calls)
			}
			rows := f.enrollments(t)
			if len(rows) != 1 || !rows[0].BaselineKnown || rows[0].FirstOptInAt == nil || !rows[0].FirstOptInAt.Equal(first.At.Truncate(time.Microsecond)) {
				t.Fatalf("binding/retry changed first opt-in: %+v", rows)
			}
		})
	}
}

func TestAutopilotConsentCaptureJournalsOptOutBeforeIdentity(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.register(t, savedConsent(true))
	first := f.store.snapshot()[0].consent
	f.heartbeat(t, savedConsent(false), 1)
	calls := f.store.snapshot()
	if len(calls) != 3 || calls[1].consent != first || calls[2].consent.OptedIn || !calls[2].consent.Supported {
		t.Fatalf("unresolved first declaration blocked the later opt-out: %+v", calls)
	}
	for _, call := range calls {
		if !errors.Is(call.err, earningsfloor.ErrIdentity) {
			t.Fatalf("unverified machine acquired financial enrollment: %+v", call)
		}
	}
	if len(f.enrollments(t)) != 0 {
		t.Fatal("provisional session enrolled")
	}
	// Adjacent retries keep the earliest timestamp, including an explicit
	// false declaration with no revision/selection.
	optOut := calls[2].consent
	state := savedConsent(false)
	state.Revision, state.SelectedModels = "", nil
	f.heartbeat(t, state, 2)
	calls = f.store.snapshot()
	if len(calls) != 6 || calls[3].consent != first || calls[4].consent != optOut || !calls[5].consent.At.After(optOut.At) {
		t.Fatalf("pending duplicate lost original transition timestamps: %+v", calls)
	}
	latestOptOut := calls[5].consent
	f.bind(t, first, consentCaptureAccount)
	// Listing must recover both raw journal entries even without a live
	// capture retry, as after loss of the original connection.
	rows := f.enrollments(t)
	if len(rows) != 1 || rows[0].OptedIn || !rows[0].FirstObservedAt.Equal(first.At.Truncate(time.Microsecond)) || !rows[0].ObservedAt.Equal(latestOptOut.At.Truncate(time.Microsecond)) {
		t.Fatalf("durable journal lost first opt-in or subsequent opt-out: %+v", rows)
	}
	// Listing leaves the socket's explicit opt-out pending. A later missing
	// declaration must not coalesce with that supported false declaration.
	f.heartbeat(t, nil, 3)
	calls = f.store.snapshot()
	if len(calls) != 9 || calls[6].consent != first || calls[7].consent != optOut {
		t.Fatalf("missing consent coalesced with explicit opt-out or changed pending history: %+v", calls)
	}
	for _, call := range calls[6:] {
		if call.err != nil {
			t.Fatalf("bound session did not flush pending declarations: %+v", call)
		}
	}
	unknown := calls[8].consent
	if unknown.OptedIn || unknown.Supported || !unknown.At.After(optOut.At) {
		t.Fatalf("missing consent became explicit opt-out or lost its receipt time: %+v", unknown)
	}
}

func TestAutopilotConsentCaptureAcceptedStateAndRepeatCheckpoints(t *testing.T) {
	f := newConsentSocket(t, nil)
	state := savedConsent(true)
	state.Enabled, state.Paused, state.ObserveOnly = false, true, true
	f.register(t, state)
	first := f.store.snapshot()[0].consent
	f.bind(t, first, consentCaptureAccount)
	f.write(t, map[string]any{"type": protocol.TypeAttestationResponse})
	f.sync(t)
	// The capture releases provider and registry locks before touching storage.
	f.store.failBeforeConsent(func(_ context.Context, declaration earningsfloor.Consent) error {
		p := f.owner.registry.GetProvider(declaration.SessionID)
		p.AutopilotRewardConsentSnapshot()
		return nil
	})
	for seq := uint64(1); seq <= 3; seq++ {
		f.heartbeat(t, state, seq)
	}
	calls := f.store.snapshot()
	if len(calls) != 5 {
		t.Fatalf("successful duplicate heartbeats skipped store checkpoints: %+v", calls)
	}
	for i := 2; i < len(calls); i++ {
		if calls[i].err != nil || !calls[i].consent.OptedIn || !calls[i].consent.Supported || !calls[i].consent.At.After(calls[i-1].consent.At) {
			t.Fatalf("repeat observation failed to advance saved consent watermark: %+v", calls)
		}
	}
	f.heartbeat(t, savedConsent(false), 2)
	if got := len(f.store.snapshot()); got != len(calls) {
		t.Fatalf("stale capacity frame journaled raw unaccepted consent: calls=%d", got)
	}
	rows := f.enrollments(t)
	if len(rows) != 1 || !rows[0].OptedIn || !rows[0].ObservedAt.Equal(calls[4].consent.At.Truncate(time.Microsecond)) {
		t.Fatalf("stale heartbeat or scheduler pause changed saved consent: %+v", rows)
	}
	f.heartbeat(t, nil, 4)
	last := f.store.snapshot()[5]
	if last.err != nil || last.consent.OptedIn || last.consent.Supported || f.enrollments(t)[0].OptedIn {
		t.Fatalf("missing field silently retained previous positive consent: %+v", last)
	}
}

func TestAutopilotConsentCaptureNeverUsesRestoredOrClaimedAccount(t *testing.T) {
	for _, token := range []string{"", "invalid-provider-token", "inactive-provider-token"} {
		t.Run(token, func(t *testing.T) {
			gate := make(chan struct{})
			f := newConsentSocket(t, &consentCaptureStore{inventoryGate: gate})
			t.Cleanup(func() { close(gate) })
			if err := f.store.CreateProviderToken(&store.ProviderToken{TokenHash: providerTokenHash("inactive-provider-token"), AccountID: consentCaptureAccount, Active: false}); err != nil {
				t.Fatal(err)
			}
			f.write(t, map[string]any{"type": protocol.TypeRegister, "auth_token": token, "account_id": consentCaptureAccount, "model_autopilot": savedConsent(true)})
			f.sync(t)
			ids := f.owner.registry.ProviderIDs()
			if len(ids) != 1 {
				t.Fatalf("registration failed: %v", ids)
			}
			// Even account state restored independently of this registration's
			// token must never authorize the capture.
			p := f.owner.registry.GetProvider(ids[0])
			p.Mu().Lock()
			p.AccountID = consentCaptureAccount
			p.Mu().Unlock()
			f.bind(t, earningsfloor.Consent{SessionID: p.ID}, consentCaptureAccount)
			f.heartbeat(t, savedConsent(true), 1)
			if len(f.store.snapshot()) != 0 || len(f.enrollments(t)) != 0 {
				t.Fatal("unvalidated token inherited a financial account")
			}
		})
	}
}

func TestAutopilotConsentCaptureWrongOwnerCannotEnroll(t *testing.T) {
	gate := make(chan struct{})
	f := newConsentSocket(t, &consentCaptureStore{inventoryGate: gate})
	t.Cleanup(func() { close(gate) })
	f.register(t, savedConsent(true))
	first := f.store.snapshot()[0].consent
	f.bind(t, first, "another-owner")
	f.heartbeat(t, savedConsent(false), 1)
	if len(f.enrollments(t)) != 0 {
		t.Fatal("authenticated session acquired another account's financial enrollment")
	}
	for _, call := range f.store.snapshot() {
		if call.consent.AccountID != consentCaptureAccount || !errors.Is(call.err, earningsfloor.ErrIdentity) {
			t.Fatalf("capture changed account to match a conflicting binding: %+v", call)
		}
	}
}

func TestAutopilotConsentCaptureUnsupportedHistoryRemainsUnknown(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*protocol.ModelAutopilotState) *protocol.ModelAutopilotState
	}{
		{"absent", func(*protocol.ModelAutopilotState) *protocol.ModelAutopilotState { return nil }},
		{"old_wire_enabled", func(s *protocol.ModelAutopilotState) *protocol.ModelAutopilotState {
			s.Enabled, s.ConsentEnabled = true, nil
			return s
		}},
		{"unsupported_protocol", func(s *protocol.ModelAutopilotState) *protocol.ModelAutopilotState { s.Protocol++; return s }},
		{"noncached", func(s *protocol.ModelAutopilotState) *protocol.ModelAutopilotState { s.CachedOnly = false; return s }},
		{"missing_revision", func(s *protocol.ModelAutopilotState) *protocol.ModelAutopilotState { s.Revision = ""; return s }},
		{"malformed_revision", func(s *protocol.ModelAutopilotState) *protocol.ModelAutopilotState {
			s.Revision = strings.Repeat("r", 65)
			return s
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newConsentSocket(t, nil)
			state := tc.change(savedConsent(true))
			f.register(t, state)
			first := f.store.snapshot()[0].consent
			f.bind(t, first, consentCaptureAccount)
			f.heartbeat(t, state, 1)
			if rows := f.enrollments(t); len(rows) != 0 {
				t.Fatalf("unsupported declaration enrolled a machine: %+v", rows)
			}
			f.heartbeat(t, savedConsent(true), 2)
			rows := f.enrollments(t)
			if len(rows) != 1 || !rows[0].OptedIn || rows[0].BaselineKnown || rows[0].FirstOptInAt != nil {
				t.Fatalf("unsupported history was mistaken for proof of earlier opt-out: %+v", rows)
			}
		})
	}
}

func TestAutopilotConsentCaptureRegistrationSurvivesLostSocket(t *testing.T) {
	f := newConsentSocket(t, nil)
	f.register(t, savedConsent(true))
	first := f.store.snapshot()[0].consent
	// Confirmed disconnects forbid later identity changes. Bind first, without
	// sending another heartbeat or retrying the pending declaration.
	f.bind(t, first, consentCaptureAccount)
	if err := f.conn.CloseNow(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 3*time.Second, "registered provider did not disconnect", func() bool {
		return f.owner.registry.GetProvider(first.SessionID) == nil
	})
	rows := f.enrollments(t)
	if len(rows) != 1 || !rows[0].OptedIn || !rows[0].BaselineKnown || rows[0].FirstOptInAt == nil || !rows[0].FirstOptInAt.Equal(first.At.Truncate(time.Microsecond)) {
		t.Fatalf("disconnect lost the original positive declaration: %+v", rows)
	}
	calls := f.store.snapshot()
	if len(calls) != 2 || calls[1].err != nil || calls[1].consent != first {
		t.Fatalf("disconnect did not retry only the original declaration: %+v", calls)
	}
}
