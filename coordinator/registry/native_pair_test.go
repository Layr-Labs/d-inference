package registry

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestNativePairNoSelfApprovalAndNoSoloAttachment(t *testing.T) {
	f := newNativePairFixture(t)
	if _, e := f.c.Reserve(f.n, hex.EncodeToString(f.policy.NativeRuntimeSHA256[:]), time.Minute); e == nil {
		t.Fatal("supplied runtime hash became approval")
	}
	if NewNativePairCoordinator(f.r, nil) != nil {
		t.Fatal("nil catalog enabled")
	}
	bad := f.policy
	bad.MaximumTransportFrame = 4096
	if _, e := NewNativeRuntimeCatalog([]NativeRuntimeApproval{bad}); e == nil {
		t.Fatal("omitted AEAD overhead admitted")
	}
	p := pairTestMember(t, f.r, "solo-native", "serial-c")
	p.memberNonce = strings.Repeat("3", 64)
	if _, e := f.c.Attach(p, p.memberNonce, &tls.ConnectionState{HandshakeComplete: true}); e == nil {
		t.Fatal("solo attached")
	}
	if _, e := f.c.Attach(p, p.memberNonce, nil); e == nil {
		t.Fatal("no actual TLS attached")
	}
}
func TestNativePairCommitPrecedesStartAndBindingUsesExactHello(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.reserve(t)
	f.prepared(t, s, 0)
	if f.phase(s) != VerifiedPairPending {
		t.Fatal("first preparation started owner")
	}
	for _, ch := range f.frames {
		select {
		case <-ch:
			t.Fatal("start before both prepared")
		default:
		}
	}
	f.prepared(t, s, 1)
	if f.phase(s) != VerifiedPairActive {
		t.Fatal("missing actual Commit")
	}
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairOwnerStart)
		b, _ := m.PayloadBytes()
		expected, _ := s.starts[rank].Canonical()
		if string(b) != string(expected) {
			t.Fatal("start substituted")
		}
	}
	for rank := range f.n {
		start, _ := s.starts[rank].Canonical()
		hello := append([]byte("DBNH\x01"), start...)
		key := make([]byte, 32)
		key[0] = byte(9 + rank)
		hello = append(hello, key...)
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairHello, hello)); e != nil {
			t.Fatal(e)
		}
	}
	expected, e := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
	if e != nil {
		t.Fatal(e)
	}
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairBinding)
		b, _ := m.PayloadBytes()
		if string(b) != string(expected) {
			t.Fatal("binding not exact")
		}
	}
}
func TestNativePairCancellationRetainsUntilActualOriginalRelease(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.active(t)
	if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairCancel, []byte("DBNC\x01"))); e != nil {
		t.Fatal(e)
	}
	pairTestDone(t, s.handle)
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("cancel released owners")
	}
	for rank := range f.n {
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[rank]))); e != nil {
			t.Fatal(e)
		}
		if rank == 0 && f.phase(s) != VerifiedPairQuarantined {
			t.Fatal("one rank released pair")
		}
	}
	if f.phase(s) != VerifiedPairReleased {
		t.Fatal("real bilateral observations did not release")
	}
}
func TestNativePairFalseCleanupAndReplayNeverRelease(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.active(t)
	receipt := nativePairReleaseReceipt(s.starts[0])
	receipt[len(receipt)-1] = 0
	m := f.signed(t, s, 0, protocol.TypeNativePairOwnerReleased, receipt)
	if e := f.c.Handle(f.n[0], m); e == nil {
		t.Fatal("missing actual transport completion admitted")
	}
	if e := f.c.Handle(f.n[0], m); e == nil {
		t.Fatal("replay admitted")
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("failed cleanup released native hold")
	}
}
func TestNativePairPreparedCannotLaunchHelloBeforeCommit(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.reserve(t)
	start, _ := s.starts[0].Canonical()
	hello := append([]byte("DBNH\x01"), start...)
	hello = append(hello, make([]byte, 32)...)
	if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairHello, hello)); e == nil {
		t.Fatal("pre-Commit hello admitted")
	}
	if f.phase(s) != VerifiedPairReleased {
		t.Fatal("never-started pending pair quarantined indefinitely")
	}
}
func TestNativePairRevocationCannotRestoreOriginalGrant(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.reserve(t)
	f.prepared(t, s, 0)
	f.c.RevokeApproval(f.policy.ID)
	pairTestDone(t, s.handle)
	if f.phase(s) != VerifiedPairReleased {
		t.Fatal("pending revocation retained physical ownership")
	}
	b, _ := s.starts[1].Canonical()
	if e := f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairPrepared, b)); e == nil {
		t.Fatal("revoked grant committed")
	}
}
func TestNativePairReconnectCannotReleaseOldActiveOwner(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.active(t)
	old := f.n[0]
	f.c.Detach(old)
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("disconnect freed active native")
	}
	f.r.Disconnect(f.p[0].ID)
	replacement := pairTestMember(t, f.r, "replacement-a", "serial-a")
	replacement.mu.Lock()
	replacement.executionRole = protocol.ExecutionRoleClusterMember
	replacement.memberNonce = strings.Repeat("4", 64)
	replacement.mu.Unlock()
	next, e := f.c.Attach(replacement, replacement.memberNonce, &tls.ConnectionState{HandshakeComplete: true})
	if e != nil {
		t.Fatal(e)
	}
	m := f.signed(t, s, 0, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[0]))
	if e = f.c.Handle(next, m); e == nil {
		t.Fatal("replacement released old owner")
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("reconnect lost quarantine")
	}
}
func TestNativePairBoundedRelayAndCancellation(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.active(t)
	f.c.mu.Lock()
	accepted := 0
	for i := 0; i < 100; i++ {
		if f.c.enqueueLocked(s, 0, protocol.TypeNativePairBinding, make([]byte, 32768)) != nil {
			break
		}
		accepted++
	}
	frames, bytes := s.queuedFrames[0], s.queuedBytes[0]
	f.c.mu.Unlock()
	if accepted > nativePairQueueFrames || frames > nativePairQueueFrames || bytes > nativePairQueueBytes {
		t.Fatal("unbounded relay")
	}
	ended := make(chan struct{})
	go func() { f.c.Cancel(s); close(ended) }()
	select {
	case <-ended:
	case <-time.After(time.Second):
		t.Fatal("cancel waited on writer")
	}
	ctx, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal("public writers did not join", e)
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("relay cancellation fabricated release")
	}
}

func TestNativePairRevokeRacingSecondPreparationNeverLeavesActive(t *testing.T) {
	f := newNativePairFixture(t)
	s := f.reserve(t)
	f.prepared(t, s, 0)
	b, _ := s.starts[1].Canonical()
	m := f.signed(t, s, 1, protocol.TypeNativePairPrepared, b)
	start := make(chan struct{})
	finished := make(chan struct{}, 2)
	go func() { <-start; _ = f.c.Handle(f.n[1], m); finished <- struct{}{} }()
	go func() { <-start; f.c.RevokeApproval(f.policy.ID); finished <- struct{}{} }()
	close(start)
	for i := 0; i < 2; i++ {
		select {
		case <-finished:
		case <-time.After(time.Second):
			t.Fatal("commit/revoke lock ordering stalled")
		}
	}
	pairTestDone(t, s.handle)
	phase := f.phase(s)
	if phase != VerifiedPairReleased && phase != VerifiedPairQuarantined {
		t.Fatal("revoked grant remained active")
	}
}
func TestNativePairWrongConnectionNonceAndSignatureRefused(t *testing.T) {
	for _, mutation := range []string{"nonce", "peer", "signature"} {
		t.Run(mutation, func(t *testing.T) {
			f := newNativePairFixture(t)
			s := f.active(t)
			m := f.signed(t, s, 0, protocol.TypeNativePairCancel, []byte("DBNC\x01"))
			connection := f.n[0]
			switch mutation {
			case "nonce":
				m.MemberNonce = f.n[1].nonce
			case "peer":
				connection = f.n[1]
			case "signature":
				m.Signature = "MAYCAQECAQE="
			}
			if e := f.c.Handle(connection, m); e == nil {
				t.Fatal("substituted bound member message admitted")
			}
			if f.phase(s) != VerifiedPairQuarantined {
				t.Fatal("failure cleared active ownership")
			}
		})
	}
}
func TestNativePairFixedLifetimeExpiresWithoutOwnerRelease(t *testing.T) {
	f := newNativePairFixture(t)
	s, e := f.c.Reserve(f.n, f.policy.ID, 500*time.Millisecond)
	if e != nil {
		t.Fatal(e)
	}
	original := s.membership.ExpiresAt
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPrepare)
		f.prepared(t, s, rank)
	}
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairOwnerStart)
		if m.ExpiresAtUnixNano != original.UnixNano() {
			t.Fatal("start refreshed lifetime")
		}
	}
	select {
	case <-s.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("original fixed lifetime did not expire")
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("deadline manufactured owner cleanup")
	}
}
