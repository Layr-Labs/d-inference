package authorization_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
)

type archiveReadinessStore struct {
	*memorystore.MemoryStore
	state store.AppAttestReadiness
}

func (s *archiveReadinessStore) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	return s.state, nil
}
func (s *archiveReadinessStore) ResolveMachineContinuity(context.Context, string, string, string, []string) (store.MachineContinuity, error) {
	return store.MachineContinuity{Machine: store.MachineIdentity{ID: "machine", Assurance: "key_bound"}}, nil
}

type failingEvidenceCompletion struct {
	*memorystore.MemoryStore
	decisions []store.AppAttestDecision
}

func (s *failingEvidenceCompletion) CompleteAppAttestEvidence(_ context.Context, _ string, decision store.AppAttestDecision) (string, error) {
	s.decisions = append(s.decisions, decision)
	return "", errors.New("temporary commit failure")
}

type capturedProofArchive struct{ evidence store.AppAttestEvidence }

func (s *capturedProofArchive) BeginAppAttestEvidence(_ context.Context, e store.AppAttestEvidence) error {
	s.evidence = e
	return nil
}
func (*capturedProofArchive) CompleteAppAttestEvidence(_ context.Context, _ string, d store.AppAttestDecision) (string, error) {
	return d.Outcome, nil
}

func archivePipeline(f *authorizationFixture, p *registry.Provider, archive store.AppAttestArchiveStore, integrity *evidence.Integrity) *exchange.Pipeline {
	budget := &storage.Budget{}
	return exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: f.store},
		Archive: archive, Enrollments: f.store, Provider: p, Budget: budget, Scope: storage.NewScope(budget), Integrity: integrity, Authorization: f.controller})
}

func archiveAttempt(f *authorizationFixture) exchange.Attempt {
	return exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "proof", Account: "account", Environment: "production", ProtocolVersion: 3},
		Credential: &store.AppAttestShadowKey{KeyID: "credential"}, Expected: "assertion"}}
}

func TestArchiveGapFencesGrantUntilNewProofIsDurablyCommitted(t *testing.T) {
	f, p, _, state := newAuthorizationFixture(t, false)
	st := &archiveReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: state}
	integrity := &evidence.Integrity{}
	identity := authorization.NewIdentity(authorization.IdentityDependencies{Controller: f.controller, Registry: f.registry,
		Operational: func() store.MachineOperationalStore { return st }, Readiness: func() store.AppAttestReadinessStore { return st }}, p, "account")
	integrity.RecordCommit("assertion", "verified")
	e := f.evidence
	eligibility.ApplyReadiness(&e, state)
	update := func() {
		identity.Update(authorization.NewVerifiedProof(e, &f.status, "proof", integrity.Dropped, integrity.Baseline()), appattest.EvaluateAuthorization(e, time.Now()))
	}
	update()
	if _, ok := f.registry.ProviderServingAuthorization(p); !ok {
		t.Fatal("initial qualified assertion was not granted")
	}
	integrity.Drop(f.controller, p)
	if integrity.Dropped() != 1 || f.controller.Current(p) != nil {
		t.Fatal("historical gap was erased or retained the prior proof")
	}
	if _, ok := f.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("unarchived input did not immediately fence the old lease")
	}
	integrity.BeginChallenge()
	e.ArchiveComplete = integrity.Complete()
	update()
	if _, ok := f.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("new challenge alone restored permission without a committed proof")
	}
	if _, err := st.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", AppID: "TEST.app", Environment: "production"}); err != nil {
		t.Fatal(err)
	}
	if err := st.BeginAppAttestEvidence(context.Background(), store.AppAttestEvidence{ID: "recovered", SessionID: p.ID, KeyID: "credential", Action: "assertion"}); err != nil {
		t.Fatal(err)
	}
	counter := uint32(1)
	outcome, err := evidence.NewCommitter(st, integrity, f.controller, p).Complete(context.Background(), "recovered", "assertion", store.AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: "credential", Owner: "owner"})
	if err != nil || outcome != "verified" || !integrity.Complete() {
		t.Fatal("new verified assertion was not durably accepted")
	}
	e.ArchiveComplete, e.AssertionAt = integrity.Complete(), time.Now().UTC()
	update()
	if lease, ok := f.registry.ProviderServingAuthorization(p); !ok || lease.IssuedAt != e.AssertionAt ||
		!f.controller.Apply(p, f.controller.Current(p), state, time.Now()) || integrity.Baseline() != 1 || integrity.Dropped() != 1 {
		t.Fatal("fresh proof did not restore permission without losing the historical gap")
	}
}

func TestArchiveCompletionFailureFencesOlderGrant(t *testing.T) {
	for _, path := range []string{"verified_commit", "deferred_rejection"} {
		t.Run(path, func(t *testing.T) {
			f, p, record, state := newAuthorizationFixture(t, false)
			a := f.controller
			a.Remember(p, record)
			if !a.Apply(p, record, state, time.Now()) {
				t.Fatal("initial grant")
			}
			mem := memorystore.NewMemory(store.Config{})
			archive := &failingEvidenceCompletion{MemoryStore: mem}
			integrity := &evidence.Integrity{}
			if path == "verified_commit" {
				if outcome, err := evidence.NewCommitter(archive, integrity, a, p).Complete(context.Background(), "pending", "assertion", store.AppAttestDecision{Outcome: "verified"}); err == nil && outcome == "verified" {
					t.Fatal("failed commit accepted")
				}
				// Restore the prior grant, then exercise the complete verified
				// proof/commit/worker-transition boundary, not only Committer.
				a.Remember(p, record)
				if !a.Apply(p, record, state, time.Now()) {
					t.Fatal("prior grant could not be restored for pipeline handoff")
				}
				private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				key := store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", AppID: "TEST.app", Environment: "production", PublicKey: elliptic.Marshal(private.Curve, private.X, private.Y)}
				if _, err := mem.InsertAppAttestShadowKey(t.Context(), key); err != nil {
					t.Fatal(err)
				}
				attempt := archiveAttempt(f)
				attempt.Challenge.Credential = &key
				attempt.Challenge.Binding.Owner, attempt.Challenge.Binding.AppID = "owner", "TEST.app"
				attempt.Challenge.Binding.PublicKey, attempt.Challenge.Binding.Challenge = p.PublicKey, "challenge"
				attempt.PreviousOutcome = "attempted"
				status := &protocol.AppAttestStatus{OSVersion: "27"}
				b := attempt.Challenge.Binding
				hash := protocol.AppAttestShadowHashV3("assert", b.Session, b.Environment, key.KeyID, b.Challenge, b.PublicKey, transcript.AccountScope(b.Account), status)
				rp := sha256.Sum256([]byte("TEST.app"))
				auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, 1)
				signed := sha256.Sum256(append(auth, hash[:]...))
				signed = sha256.Sum256(signed[:])
				signature, err := ecdsa.SignASN1(rand.Reader, private, signed[:])
				if err != nil {
					t.Fatal(err)
				}
				body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
				if err != nil {
					t.Fatal(err)
				}
				lastOutcome, transitions := "attempted", 0
				budget := &storage.Budget{}
				pipeline := exchange.NewPipeline(exchange.PipelineDependencies{
					Verification: exchange.Dependencies{Keys: mem, Verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"}),
						Observe: func(stage, outcome string, _ *appattest.Key, _ protocol.AppAttestShadowPayload) {
							if stage != "archive" {
								lastOutcome = outcome
							}
						}},
					Archive: archive, Enrollments: mem, Provider: p, Budget: budget, Scope: storage.NewScope(budget), Integrity: integrity, Authorization: a,
					Transition: func(exchange.Result, protocol.AppAttestShadowPayload) string { transitions++; return lastOutcome },
				})
				result := pipeline.Handle(t.Context(), attempt, protocol.AppAttestShadowPayload{Session: b.Session, Action: "assertion", KeyID: key.KeyID, Challenge: b.Challenge,
					Result: "ok", Proof: base64.StdEncoding.EncodeToString(body), ProtocolVersion: 3, Status: status})
				if result.Next != "stop" || result.Outcome != "storage_error" || !recovery.RetryableOutcome(result.Outcome) || transitions != 1 {
					t.Fatalf("archive failure lost at worker transition: next=%s outcome=%s transitions=%d", result.Next, result.Outcome, transitions)
				}
				if len(archive.decisions) < 2 || archive.decisions[1].Outcome != "verified" {
					t.Fatal("proof did not reach the durable verified commit")
				}
			} else {
				archivePipeline(f, p, archive, integrity).Handle(context.Background(), archiveAttempt(f), protocol.AppAttestShadowPayload{Session: "proof", Action: "assertion", Result: "apple_error", Proof: "!"})
			}
			if integrity.Dropped() == 0 || a.Current(p) != nil {
				t.Fatal("completion failure did not preserve the gap and forget the old proof")
			}
			if _, ok := f.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("old App Attest lease survived unarchived completion")
			}
		})
	}
}

func TestIdleDuplicateIsArchivedWithoutChangingPriorLease(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, false)
	a := f.controller
	a.Remember(p, record)
	if !a.Apply(p, record, state, time.Now()) {
		t.Fatal("initial grant")
	}
	before := p.GetAppAttestServingAuthorization()
	integrity, archive := &evidence.Integrity{}, &capturedProofArchive{}
	attempt := archiveAttempt(f)
	attempt.Challenge.Expected = ""
	reply := protocol.AppAttestShadowPayload{Session: "proof", Action: "assertion", Result: "ok", Proof: "AQID"}
	if next := archivePipeline(f, p, archive, integrity).Handle(context.Background(), attempt, reply).Next; next != "ignore" {
		t.Fatalf("archived duplicate stopped the serving session: %s", next)
	}
	if archive.evidence.ProofField != reply.Proof || integrity.Dropped() != 0 || a.Current(p) != record || p.GetAppAttestServingAuthorization() != before {
		t.Fatal("idle duplicate was not retained or changed the accepted lease")
	}
}

func TestLateWrongSessionReplyKeepsTimerOnlyWhenArchived(t *testing.T) {
	for _, failArchive := range []bool{false, true} {
		t.Run(map[bool]string{false: "archived", true: "archive_failed"}[failArchive], func(t *testing.T) {
			f, p, record, state := newAuthorizationFixture(t, false)
			a := f.controller
			a.Remember(p, record)
			if !a.Apply(p, record, state, time.Now()) {
				t.Fatal("initial grant")
			}
			integrity := &evidence.Integrity{}
			var archive store.AppAttestArchiveStore
			var archived *capturedProofArchive
			if failArchive {
				archive = &failingEvidenceCompletion{MemoryStore: memorystore.NewMemory(store.Config{})}
			} else {
				archived = &capturedProofArchive{}
				archive = archived
			}
			reply := protocol.AppAttestShadowPayload{Session: "timed-out-attempt", Action: "assertion", Result: "ok", Proof: "AQID"}
			keepTimer, result := archivePipeline(f, p, archive, integrity).RetainUnsolicited(context.Background(), archiveAttempt(f), reply)
			if failArchive {
				if keepTimer || result.Outcome != "storage_error" || !recovery.RetryableOutcome(result.Outcome) || integrity.Dropped() != 1 || a.Current(p) != nil {
					t.Fatal("failed late-proof archive delayed recovery or retained the old proof")
				}
				if _, ok := f.registry.ProviderServingAuthorization(p); ok {
					t.Fatal("failed late-proof archive retained a serving lease")
				}
			} else if !keepTimer || archived.evidence.ProofField != reply.Proof || integrity.Dropped() != 0 || a.Current(p) != record {
				t.Fatal("archived late proof changed the active assertion schedule or lease")
			}
		})
	}
}
