package exchange_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func shadowKeyID(fill byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

type failingShadowKeyRead struct{ *memorystore.MemoryStore }

func (*failingShadowKeyRead) GetAppAttestShadowKey(context.Context, string) (*store.AppAttestShadowKey, error) {
	return nil, errors.New("database unavailable")
}

// observedOutcomes collects every observation as "stage:outcome".
type observedOutcomes []string

func (o *observedOutcomes) observe(stage, outcome string, _ *appattest.Key, _ protocol.AppAttestShadowPayload) {
	*o = append(*o, stage+":"+outcome)
}

// readyExchange is one issued ready challenge handled by the real pipeline.
func readyExchange(verification exchange.Dependencies) (*exchange.Pipeline, exchange.Attempt) {
	budget := &storagebudget.Budget{}
	mem := memorystore.NewMemory(store.Config{})
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: verification, Archive: mem, Enrollments: mem,
		Provider: newSessionProvider("endpoint", "se"), Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: &evidence.Integrity{}})
	attempt := exchange.Attempt{Challenge: exchange.Challenge{Expected: "ready", Binding: transcript.Binding{Session: "session", Owner: "owner", Account: "account",
		PublicKey: "endpoint", AppID: "TEST.app", Environment: "production", ProtocolVersion: 3}}}
	return pipeline, attempt
}

func readyReply(keyID string) protocol.AppAttestShadowPayload {
	return protocol.AppAttestShadowPayload{Session: "session", Action: "ready", Result: "ok", KeyID: keyID}
}

func TestReadyReplyStopsOnKeyLookupFailure(t *testing.T) {
	pipeline, attempt := readyExchange(exchange.Dependencies{Keys: &failingShadowKeyRead{memorystore.NewMemory(store.Config{})}})
	result := pipeline.Handle(context.Background(), attempt, readyReply(shadowKeyID(1)))
	if result.Next != "stop" || result.Outcome != "storage_error" {
		t.Fatalf("next=%q outcome=%q", result.Next, result.Outcome)
	}
	if result.Credential != nil {
		t.Fatal("failed lookup selected a key")
	}
}

func TestReadyReplyRejectsKeyOfAnotherOwnerOrPolicy(t *testing.T) {
	for _, tc := range []struct {
		name        string
		key         store.AppAttestShadowKey
		ownerMatch  bool
		wantNext    string
		wantOutcome string
	}{
		{"matching owner and policy", store.AppAttestShadowKey{Owner: "owner", AccountID: "account", AppID: "TEST.app", Environment: "production"}, true, "assert", ""},
		{"other owner and account", store.AppAttestShadowKey{Owner: "someone", AccountID: "other-account", MachineID: "machine", AppID: "TEST.app", Environment: "production"}, false, "stop", "key_owner_or_policy"},
		{"other environment", store.AppAttestShadowKey{Owner: "owner", AccountID: "account", AppID: "TEST.app", Environment: "development"}, true, "stop", "key_owner_or_policy"},
		{"other app", store.AppAttestShadowKey{Owner: "owner", AccountID: "account", AppID: "OTHER.app", Environment: "production"}, true, "stop", "key_owner_or_policy"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mem := memorystore.NewMemory(store.Config{})
			tc.key.KeyID, tc.key.PublicKey = shadowKeyID(2), []byte{1}
			if _, err := mem.InsertAppAttestShadowKey(context.Background(), tc.key); err != nil {
				t.Fatal(err)
			}
			pipeline, attempt := readyExchange(exchange.Dependencies{Keys: mem,
				OwnerMatches: func(context.Context, *store.AppAttestShadowKey) bool { return tc.ownerMatch }})
			result := pipeline.Handle(context.Background(), attempt, readyReply(tc.key.KeyID))
			if result.Next != tc.wantNext || tc.wantOutcome != "" && result.Outcome != tc.wantOutcome {
				t.Fatalf("next=%q outcome=%q", result.Next, result.Outcome)
			}
			if accepted := tc.wantNext == "assert"; accepted != (result.Credential != nil && result.Owner == tc.key.Owner) {
				t.Fatalf("credential %+v owner %q", result.Credential, result.Owner)
			}
		})
	}
}

func TestProofReplyWithoutPreparedContextStops(t *testing.T) {
	var observed observedOutcomes
	key := &store.AppAttestShadowKey{KeyID: shadowKeyID(3)}
	c := exchange.Challenge{Expected: "assertion", Credential: key, Binding: transcript.Binding{Session: "session", Challenge: "challenge"}}
	reply := protocol.AppAttestShadowPayload{Session: "session", Action: "assertion", Result: "ok", KeyID: key.KeyID, Challenge: "challenge", Proof: base64.StdEncoding.EncodeToString([]byte("proof"))}
	if result := exchange.Verify(context.Background(), exchange.Dependencies{Observe: observed.observe}, c, reply); result.Next != "stop" || !slices.Equal(observed, observedOutcomes{"assertion:enrollment_context"}) {
		t.Fatalf("next=%q observed=%v", result.Next, observed)
	}
}

func TestInvalidAttestationIsRejectedWithoutStoringKey(t *testing.T) {
	mem := memorystore.NewMemory(store.Config{})
	var observed observedOutcomes
	key := &store.AppAttestShadowKey{KeyID: shadowKeyID(4)}
	deps := exchange.Dependencies{Keys: mem, Verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"}), Observe: observed.observe,
		Commit: func(context.Context, store.AppAttestDecision) bool {
			t.Fatal("rejected attestation committed")
			return false
		}}
	c := exchange.Challenge{Expected: "attestation", Credential: key, Prepared: &evidence.Prepared{}, Binding: transcript.Binding{Session: "session", Challenge: "challenge", AppID: "TEST.app", Environment: "production"}}
	reply := protocol.AppAttestShadowPayload{Session: "session", Action: "attestation", Result: "ok", KeyID: key.KeyID, Challenge: "challenge", Proof: base64.StdEncoding.EncodeToString([]byte("not an attestation"))}
	if result := exchange.Verify(context.Background(), deps, c, reply); result.Next != "stop" || result.Credential != nil {
		t.Fatalf("result %+v", result)
	}
	if len(observed) != 1 || observed[0] == "attestation:verified" || !strings.HasPrefix(observed[0], "attestation:") {
		t.Fatalf("rejection not observed: %v", observed)
	}
	if stored, _ := mem.GetAppAttestShadowKey(context.Background(), key.KeyID); stored != nil {
		t.Fatal("rejected attestation stored a credential")
	}
}

// A worker that finds every verifier slot busy still archives the reply, as a
// rejection, without verifying it.
func TestVerifierBusyReplyIsArchivedAsRejection(t *testing.T) {
	var observed observedOutcomes
	pipeline, attempt := readyExchange(exchange.Dependencies{Keys: &failingShadowKeyRead{memorystore.NewMemory(store.Config{})}, Observe: observed.observe})
	attempt.Rejection = "verifier_busy"
	result := pipeline.Handle(context.Background(), attempt, readyReply(shadowKeyID(5)))
	if result.Next != "stop" || result.Outcome != "verifier_busy" || !slices.Equal(observed, observedOutcomes{"archive:verifier_busy"}) {
		t.Fatalf("next=%q outcome=%q observed=%v", result.Next, result.Outcome, observed)
	}
}
