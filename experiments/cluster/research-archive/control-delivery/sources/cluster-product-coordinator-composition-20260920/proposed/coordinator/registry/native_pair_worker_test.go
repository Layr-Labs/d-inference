package registry

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
	"time"
)

func protectedWorkerFixture(t *testing.T, mesh bool) (*nativePairFixture, *NativePairSession, [32]byte) {
	t.Helper()
	f := newNativePairFixture(t)
	// Explicit fixture-only approval installed BEFORE reserving any real grant.
	f.policy.Schedule = 1
	f.policy.MaximumPlaintext = 131072
	f.policy.MaximumTransportFrame = 131112
	f.policy.MaximumRecords = 1024
	f.policy.MaximumCumulativePlaintext = 16777216
	catalog, e := NewNativeRuntimeCatalog([]NativeRuntimeApproval{f.policy})
	if e != nil {
		t.Fatal(e)
	}
	f.c.mu.Lock()
	f.c.catalog = catalog
	f.c.mu.Unlock()
	s := f.active(t)
	for rank := range f.n {
		b, _ := s.starts[rank].Canonical()
		h := sha256.Sum256(b)
		if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairWorkerAttach, append([]byte("DBWX\x01"), h[:]...))); e != nil {
			t.Fatal(e)
		}
	}
	if !mesh {
		return f, s, [32]byte{}
	}
	for rank := range f.n {
		b, _ := s.starts[rank].Canonical()
		hello := append([]byte("DBNH\x01"), b...)
		key := make([]byte, 32)
		key[0] = byte(9 + rank)
		if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairHello, append(hello, key...))); e != nil {
			t.Fatal(e)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairBinding)
	}
	for rank := range f.n {
		if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairConfirmation, bytes.Repeat([]byte{byte(rank + 1)}, 32))); e != nil {
			t.Fatal(e)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPeerConfirmation)
	}
	b, _ := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
	digest := sha256.Sum256(b)
	for rank := range f.n {
		if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairKeyConfirmed, protocol.NativePairKeyConfirmed(digest))); e != nil {
			t.Fatal(e)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairMeshReady)
	}
	for round := uint8(0); round < 4; round++ {
		for rank := range f.n {
			p, _ := protocol.NativePairMeshPacket(digest, uint8(rank), round, meshValue(rank, round), false)
			if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairMesh, p)); e != nil {
				t.Fatal(e)
			}
		}
		for rank := range f.n {
			f.read(t, rank, protocol.TypeNativePairMeshReply)
		}
	}
	return f, s, digest
}
func workerFixturePacket(kind byte, digest [32]byte, slack uint64, payload []byte) []byte {
	b := append([]byte{'D', 'B', 'N', 'W', 1, kind}, digest[:]...)
	b = binary.BigEndian.AppendUint64(b, slack)
	b = binary.BigEndian.AppendUint64(b, 0)
	b = binary.BigEndian.AppendUint32(b, uint32(len(payload)))
	return append(b, payload...)
}
func TestNativePairWorkerRelayRequiresBothReadyAndPreservesOriginalScope(t *testing.T) {
	f, s, d := protectedWorkerFixture(t, true)
	// Opaque fixture bytes test transport, not a native Ready or allocation claim.
	for rank := range f.n {
		p := workerFixturePacket(1, d, 0, []byte("fixture-ready"))
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairWorkerReady, p)); e != nil {
			t.Fatal(e)
		}
	}
	f.read(t, 0, protocol.TypeNativePairWorkerReady)
	original := workerFixturePacket(2, d, uint64(time.Second), []byte("fixture-command"))
	if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairWorkerCommand, original)); e != nil {
		t.Fatal(e)
	}
	got := f.read(t, 1, protocol.TypeNativePairWorkerCommand)
	payload, _ := got.PayloadBytes()
	if !bytes.Equal(payload, original) || got.ExpiresAtUnixNano != s.membership.ExpiresAt.UnixNano() {
		t.Fatal("relay changed bytes/deadline")
	}
	event := workerFixturePacket(3, d, 0, []byte("fixture-event"))
	if e := f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairWorkerEvent, event)); e != nil {
		t.Fatal(e)
	}
	f.read(t, 0, protocol.TypeNativePairWorkerEvent)
	if f.phase(s) != VerifiedPairActive {
		t.Fatal("worker record changed ownership")
	}
}
func TestNativePairWorkerWrongDirectionContextAndExpiredSlackQuarantine(t *testing.T) {
	for _, bad := range []string{"before-ready", "wrong-rank", "context", "expired-slack", "repeat-ready"} {
		t.Run(bad, func(t *testing.T) {
			f, s, d := protectedWorkerFixture(t, true)
			kind := protocol.TypeNativePairWorkerCommand
			rank := 0
			slack := uint64(0)
			if bad != "before-ready" {
				for r := range f.n {
					p := workerFixturePacket(1, d, 0, []byte("fixture-ready"))
					if e := f.c.Handle(f.n[r], f.signed(t, s, r, protocol.TypeNativePairWorkerReady, p)); e != nil {
						t.Fatal(e)
					}
				}
				f.read(t, 0, protocol.TypeNativePairWorkerReady)
			}
			if bad == "wrong-rank" {
				rank = 1
			}
			if bad == "context" {
				d[0] ^= 1
			}
			if bad == "expired-slack" {
				slack = uint64(time.Hour)
			}
			tag := byte(2)
			if bad == "repeat-ready" {
				kind = protocol.TypeNativePairWorkerReady
				tag = 1
			}
			p := workerFixturePacket(tag, d, slack, []byte("fixture"))
			if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, kind, p)); e == nil {
				t.Fatal("bad request record accepted")
			}
			if f.phase(s) != VerifiedPairQuarantined {
				t.Fatal("failed request freed owners")
			}
		})
	}
}
func TestNativePairWorkerCleanupNeedsBothActualOriginalReleasesBeforeReuse(t *testing.T) {
	f, s, _ := protectedWorkerFixture(t, false)
	f.c.Cancel(s)
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairCancel)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal(e)
	}
	if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[0]))); e != nil {
		t.Fatal(e)
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("one release freed pair")
	}
	for _, ch := range f.frames {
		select {
		case <-ch:
			t.Fatal("aggregate before bilateral release")
		default:
		}
	}
	if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e == nil {
		t.Fatal("replacement before bilateral proof")
	}
	if e := f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[1]))); e != nil {
		t.Fatal(e)
	}
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairWorkersReleased)
		b, _ := m.PayloadBytes()
		if !bytes.Equal(b, nativePairWorkersReleased(s.starts)) {
			t.Fatal("receipt changed original starts")
		}
	}
	f.c.mu.Lock()
	done := s.workerReleaseDone
	f.c.mu.Unlock()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("publication task did not join")
	}
	if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e != nil {
		t.Fatal("replacement blocked after exact proof", e)
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPrepare)
	}
}
