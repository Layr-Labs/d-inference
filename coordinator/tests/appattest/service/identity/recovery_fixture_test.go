package identity_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func rotationKeyID(fill byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

type rotationHarness struct {
	mem     *memorystore.MemoryStore
	percent int
	events  []map[string]any
}

func newRotationHarness(t *testing.T, percent int) *rotationHarness {
	t.Helper()
	return &rotationHarness{mem: memorystore.NewMemory(store.Config{}), percent: percent}
}

func (h *rotationHarness) enroll(t *testing.T, keyID, machine string) {
	t.Helper()
	if _, err := h.mem.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: keyID, Owner: "owner", AccountID: "account", MachineID: machine, AppID: "TEST.app", Environment: "production", PublicKey: []byte{1}}); err != nil {
		t.Fatal(err)
	}
}

// The fixture retains issued challenge inputs, not a copy of Session's state.
// Every reply goes through the real Pipeline, archive and verifier.
type rotationExchange struct {
	attempt    exchange.Attempt
	last       exchange.ReplyResult
	deps       exchange.PipelineDependencies
	rotation   *recovery.Rotation
	enrollment *recovery.Enrollment
	inventory  *inventory.Session
	provider   *registry.Provider
	integrity  evidence.Integrity
	h          *rotationHarness
}

func (h *rotationHarness) session(protocolVersion int) *rotationExchange {
	return h.exchange(protocolVersion, &registry.Provider{ID: "provider", PublicKey: "endpoint"})
}

func (h *rotationHarness) exchange(protocolVersion int, provider *registry.Provider) *rotationExchange {
	x := &rotationExchange{h: h, provider: provider, attempt: exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "session", Account: "account", Owner: "owner", PublicKey: provider.PublicKey, AppID: "TEST.app", Environment: "production", ProtocolVersion: protocolVersion}}}}
	budget := &storage.Budget{}
	scope := storage.NewScope(budget)
	canonical := func(ctx context.Context, fallback string) string {
		machine := fallback
		if x.inventory != nil && x.inventory.Identity().ID != "" {
			machine = x.inventory.Identity().ID
		}
		if machine == "" {
			return ""
		}
		if id, err := h.mem.CanonicalMachineID(ctx, machine); err == nil && id != "" {
			return id
		}
		return machine
	}
	x.rotation = recovery.NewRotation(recovery.RotationDependencies{Store: func() store.AppAttestKeyRotationStore { return h.mem }, Account: "account", Percent: h.percent, CanonicalMachine: canonical, Acquire: scope.Acquire, Observe: func(outcome string) {
		h.events = append(h.events, map[string]any{"stage": "rotation", "outcome": outcome})
	}})
	x.enrollment = recovery.NewEnrollment(recovery.EnrollmentDependencies{Store: func() store.AppAttestKeyRotationStore { return h.mem }, Account: "account", CanonicalMachine: canonical, Acquire: scope.Acquire, AcquireWithin: func(context.Context, time.Duration) (func(), bool) { return scope.Acquire() }, Observe: func(outcome string) {
		h.events = append(h.events, map[string]any{"stage": "recovery", "outcome": outcome})
	}})
	x.deps = exchange.PipelineDependencies{Archive: h.mem, Enrollments: h.mem, Provider: provider, Budget: budget, Scope: scope, Integrity: &x.integrity,
		Verification: exchange.Dependencies{Keys: h.mem, Verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"}), Rotate: x.rotation.Request,
			OwnerMatches: func(_ context.Context, key *store.AppAttestShadowKey) bool {
				return key.Owner == "owner" && key.AppID == "TEST.app" && key.Environment == "production"
			},
			Observe: func(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
				e := observation.Format(observation.Event{Provider: provider, Session: x.attempt.Challenge.Binding.Session, Account: "account", Stage: stage, Outcome: outcome, Metadata: metadata, Reply: reply})
				h.events = append(h.events, e.Fields)
			}}}
	return x
}

func (x *rotationExchange) accept(ctx context.Context, reply protocol.AppAttestShadowPayload) string {
	x.last = exchange.NewPipeline(x.deps).Handle(ctx, x.attempt, reply)
	if x.last.Credential != nil {
		x.attempt.Challenge.Credential = x.last.Credential
	}
	if x.last.ReadyObserved {
		x.attempt.ReadyContext = x.last.ReadyContext
	}
	return x.last.Next
}

func (h *rotationHarness) assertionFailure(t *testing.T, x *rotationExchange, keyID, result string, appleError *protocol.AppAttestAppleError) {
	t.Helper()
	key, _ := h.mem.GetAppAttestShadowKey(context.Background(), keyID)
	if key == nil {
		key = &store.AppAttestShadowKey{KeyID: keyID}
	}
	x.attempt.Challenge.Credential = key
	x.attempt.Challenge.Expected, x.attempt.Challenge.Binding.Challenge, x.attempt.Challenge.Started = "assertion", "challenge", time.Time{}
	if next := x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "assertion", KeyID: keyID, Result: result, AppleError: appleError}); next != "stop" {
		t.Fatalf("failure continued the exchange: %s", next)
	}
}

func (h *rotationHarness) ready(t *testing.T, x *rotationExchange, keyID string) string {
	t.Helper()
	x.rotation.BeginAttempt()
	x.attempt.Challenge.Credential, x.attempt.Challenge.Expected, x.attempt.Challenge.Started = nil, "ready", time.Time{}
	return x.accept(context.Background(), protocol.AppAttestShadowPayload{Session: x.attempt.Challenge.Binding.Session, Action: "ready", Result: "ok", KeyID: keyID})
}

func (h *rotationHarness) rotationOutcomes() []string {
	var outcomes []string
	for _, e := range h.events {
		if e["stage"] == "rotation" {
			outcomes = append(outcomes, e["outcome"].(string))
		}
	}
	h.events = nil
	return outcomes
}

var deadKeyError = &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 0}

func (x *rotationExchange) drive(ctx context.Context, attempt func(context.Context, recovery.Binding) recovery.Outcome, wait func(context.Context, time.Duration) bool, failure func(string)) {
	recovery.NewDriver(recovery.DriverDependencies{
		Attempt: func(ctx context.Context, binding recovery.Binding) recovery.Outcome {
			x.rotation.BeginAttempt()
			return attempt(ctx, binding)
		}, Rebind: func(binding recovery.Binding) {
			bindingInput := x.attempt.Challenge.Binding
			bindingInput.Session, bindingInput.Challenge = binding.Session, ""
			x.attempt = exchange.Attempt{Challenge: exchange.Challenge{Binding: bindingInput}}
		}, Wait: wait, BackoffRemaining: x.enrollment.Remaining,
		RotationDue: func(o recovery.Outcome) bool {
			return x.rotation.RetryDue(o.Reason, x.attempt.Challenge.Expected, x.attempt.Challenge.Credential)
		},
		EnrollmentDue: func(o recovery.Outcome) bool { return x.enrollment.Due(o.Reason, x.attempt.Challenge.Expected) }, ObserveFailure: failure,
	}, recovery.Binding{Session: x.attempt.Challenge.Binding.Session}).Run(ctx)
}
