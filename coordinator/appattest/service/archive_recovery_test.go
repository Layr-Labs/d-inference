package service

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/fxamacker/cbor/v2"
)

// The counter baseline must belong to the issued challenge. Capturing it when
// dequeuing A would absorb the loss of B and make an older proof appear complete.
func TestQueuedAssertionCannotAbsorbLaterInboxDrop(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory(store.Config{})
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := newSessionProvider(endpoint, "se")
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	record := store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", PublicKey: public, AppID: "TEST.app", Environment: "production"}
	if _, err := st.InsertAppAttestShadowKey(ctx, record); err != nil {
		t.Fatal(err)
	}
	x := &Session{s: &Service{store: st, config: Config{AppID: "TEST.app", Environment: "production"}},
		provider: p, in: make(chan protocol.AppAttestShadowPayload, 1), id: "session", owner: "owner", publicKey: endpoint,
		challenge: "challenge-a", expected: "assertion", key: &record, store: st, archive: st,
		verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})}
	proof := func(counter byte) protocol.AppAttestShadowPayload {
		t.Helper()
		rp := sha256.Sum256([]byte("TEST.app"))
		auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, counter)
		hash := protocol.AppAttestShadowHash("assert", x.id, "production", record.KeyID, x.challenge, x.publicKey)
		signed := sha256.Sum256(append(auth, hash[:]...))
		signed = sha256.Sum256(signed[:])
		signature, err := ecdsa.SignASN1(rand.Reader, key, signed[:])
		if err != nil {
			t.Fatal(err)
		}
		body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
		if err != nil {
			t.Fatal(err)
		}
		return protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", Result: "ok", KeyID: record.KeyID,
			Challenge: x.challenge, Proof: base64.StdEncoding.EncodeToString(body)}
	}
	x.beginAssertionChallenge()
	x.offer(proof(1)) // A waits in the one-slot inbox.
	x.offer(proof(1)) // B cannot be archived and is counted as dropped.
	if x.dropped.Load() != 1 {
		t.Fatal("later inbox loss was not counted")
	}
	if next := x.handle(ctx, <-x.in); next != "wait" {
		t.Fatalf("older assertion was not independently verified: %s", next)
	}
	if !x.assertionArchived || x.proofArchiveComplete() {
		t.Fatal("older archived proof absorbed a later unarchived input")
	}
	if v := appattest.EvaluateAuthorization(appattest.AuthorizationEvidence{ArchiveComplete: x.proofArchiveComplete()}, time.Now()); !slices.Contains(v.Reasons, "evidence_archive_gap") {
		t.Fatal("older proof escaped the archive policy gate")
	}
	x.challenge = "challenge-c"
	x.beginAssertionChallenge()
	if next := x.handle(ctx, proof(2)); next != "wait" || !x.proofArchiveComplete() {
		t.Fatalf("fresh archived assertion did not recover after the historical gap: %s", next)
	}
	stored, err := st.GetAppAttestShadowKey(ctx, record.KeyID)
	if err != nil || stored.Counter != 2 || x.dropped.Load() != 1 {
		t.Fatal("fresh counter or cumulative gap audit was lost")
	}
}

func TestArchiveGapFencesGrantUntilNewProofIsDurablyCommitted(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	st := &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: state}
	s.store = st
	x := sessionForAuthorization(s, p, record)
	x.archive = st
	x.expected = "assertion"
	x.owner = "owner"
	x.assertionArchived = true
	e := record.evidence
	applyAppAttestReadiness(&e, state)
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if _, ok := s.registry.ProviderServingAuthorization(p); !ok {
		t.Fatal("initial qualified assertion was not granted")
	}
	x.markDropped()
	if x.dropped.Load() != 1 || s.authorizer.current[p] != nil {
		t.Fatal("historical gap was erased or retained the prior proof")
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("unarchived input did not immediately fence the old lease")
	}
	x.beginAssertionChallenge()
	e.ArchiveComplete = x.proofArchiveComplete()
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("new challenge alone restored permission without a committed proof")
	}
	if _, err := st.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: "credential", Owner: "owner", AppID: "TEST.app", Environment: "production"}); err != nil {
		t.Fatal(err)
	}
	if err := st.BeginAppAttestEvidence(context.Background(), store.AppAttestEvidence{ID: "recovered", SessionID: p.ID, KeyID: "credential", Action: "assertion"}); err != nil {
		t.Fatal(err)
	}
	x.evidenceID = "recovered"
	counter := uint32(1)
	if !x.commitEvidence(context.Background(), store.AppAttestDecision{Outcome: "verified", Counter: &counter, KeyID: "credential", Owner: "owner"}) || !x.proofArchiveComplete() {
		t.Fatal("new verified assertion was not durably accepted")
	}
	e.ArchiveComplete = x.proofArchiveComplete()
	e.AssertionAt = time.Now().UTC()
	x.updateServingAuthorization(&record.status, e, appattest.EvaluateAuthorization(e, time.Now()))
	if lease, ok := s.registry.ProviderServingAuthorization(p); !ok || lease.IssuedAt != e.AssertionAt ||
		s.authorizer.current[p].dropBaseline != 1 || x.dropped.Load() != 1 {
		t.Fatal("fresh proof did not restore permission without losing the historical gap")
	}
}

func TestDroppedInputAndGrantAreSerialized(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	a := s.authorizer
	a.remember(p, record)
	if !a.apply(p, record, state, time.Now()) {
		t.Fatal("initial grant")
	}
	x := sessionForAuthorization(s, p, record)
	a.mu.Lock()
	started, done := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		x.markDropped()
		close(done)
	}()
	<-started
	select {
	case <-done:
		a.mu.Unlock()
		t.Fatal("drop completed before the grant lock was released")
	case <-time.After(10 * time.Millisecond):
	}
	if x.dropped.Load() != 0 {
		a.mu.Unlock()
		t.Fatal("gap counter advanced outside the grant lock")
	}
	a.mu.Unlock()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("drop did not complete after the grant lock was released")
	}
	if x.dropped.Load() != 1 || a.current[p] != nil {
		t.Fatal("drop did not remove the previous proof")
	}
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("drop retained an active lease")
	}
	s.store = &authorizationBatchStore{Store: s.store, state: map[string]store.AppAttestReadiness{"credential": state}}
	a.refresh(context.Background())
	if _, ok := s.registry.ProviderServingAuthorization(p); ok {
		t.Fatal("refresh recreated a grant after the proof was forgotten")
	}
}

func TestArchiveCompletionFailureFencesOlderGrant(t *testing.T) {
	for _, path := range []string{"verified_commit", "deferred_rejection"} {
		t.Run(path, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			a := s.authorizer
			a.remember(p, record)
			if !a.apply(p, record, state, time.Now()) {
				t.Fatal("initial grant")
			}
			mem := store.NewMemory(store.Config{})
			x := sessionForAuthorization(s, p, record)
			x.archive = &failingEvidenceCompletion{MemoryStore: mem}
			x.expected = "assertion"
			x.evidenceID = ""
			if path == "verified_commit" {
				x.evidenceID = "pending"
				if x.commitEvidence(context.Background(), store.AppAttestDecision{Outcome: "verified"}) {
					t.Fatal("failed commit accepted")
				}
			} else {
				// The invalid proof is archived first; its deferred completion
				// fails after the exchange already returned a client error.
				x.handle(context.Background(), protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", Result: "apple_error", Proof: "!"})
			}
			if x.dropped.Load() == 0 || a.current[p] != nil {
				t.Fatal("completion failure did not preserve the gap and forget the old proof")
			}
			if _, ok := s.registry.ProviderServingAuthorization(p); ok {
				t.Fatal("old App Attest lease survived unarchived completion")
			}
		})
	}
}

func TestIdleDuplicateIsArchivedWithoutChangingPriorLease(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	a := s.authorizer
	a.remember(p, record)
	if !a.apply(p, record, state, time.Now()) {
		t.Fatal("initial grant")
	}
	before := p.GetAppAttestServingAuthorization()
	x := sessionForAuthorization(s, p, record)
	x.expected = "" // The next assertion is scheduled but has not been issued.
	archive := &capturedProofArchive{}
	x.archive = archive
	reply := protocol.AppAttestShadowPayload{Session: x.id, Action: "assertion", Result: "ok", Proof: "AQID"}
	if next := x.handle(context.Background(), reply); next != "ignore" {
		t.Fatalf("archived duplicate stopped the serving session: %s", next)
	}
	if archive.evidence.ProofField != reply.Proof || x.dropped.Load() != 0 || a.current[p] != record ||
		p.GetAppAttestServingAuthorization() != before {
		t.Fatal("idle duplicate was not retained or changed the accepted lease")
	}
}

func TestLateWrongSessionReplyKeepsTimerOnlyWhenArchived(t *testing.T) {
	for _, failArchive := range []bool{false, true} {
		t.Run(map[bool]string{false: "archived", true: "archive_failed"}[failArchive], func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			a := s.authorizer
			a.remember(p, record)
			if !a.apply(p, record, state, time.Now()) {
				t.Fatal("initial grant")
			}
			x := sessionForAuthorization(s, p, record)
			x.expected = "assertion"
			var archived *capturedProofArchive
			if failArchive {
				x.archive = &failingEvidenceCompletion{MemoryStore: store.NewMemory(store.Config{})}
			} else {
				archived = &capturedProofArchive{}
				x.archive = archived
			}
			reply := protocol.AppAttestShadowPayload{Session: "timed-out-attempt", Action: "assertion", Result: "ok", Proof: "AQID"}
			keepTimer := x.archiveUnsolicitedReply(context.Background(), reply)
			if failArchive {
				if keepTimer || x.lastOutcome != "storage_error" || !retryableAppAttestOutcome(x.lastOutcome) ||
					x.dropped.Load() != 1 || a.current[p] != nil {
					t.Fatal("failed late-proof archive delayed recovery or retained the old proof")
				}
				if _, ok := s.registry.ProviderServingAuthorization(p); ok {
					t.Fatal("failed late-proof archive retained a serving lease")
				}
			} else if !keepTimer || archived.evidence.ProofField != reply.Proof || x.dropped.Load() != 0 ||
				a.current[p] != record {
				t.Fatal("archived late proof changed the active assertion schedule or lease")
			}
		})
	}
}
