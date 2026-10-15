package registry

import (
	"bytes"
	"crypto/sha256"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
	"time"
)

func meshFixture(t *testing.T, confirmed bool) (*nativePairFixture, *NativePairSession, [32]byte) {
	t.Helper()
	f := newNativePairFixture(t)
	s := f.active(t)
	for rank := range f.n {
		start, _ := s.starts[rank].Canonical()
		hello := append([]byte("DBNH\x01"), start...)
		key := make([]byte, 32)
		key[0] = byte(9 + rank)
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairHello, append(hello, key...))); e != nil {
			t.Fatal(e)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairBinding)
	}
	for rank := range f.n {
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairConfirmation, bytes.Repeat([]byte{byte(rank + 1)}, 32))); e != nil {
			t.Fatal(e)
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPeerConfirmation)
	}
	binding, e := protocol.NativeAuthorizationBinding(s.hellos, s.starts)
	if e != nil {
		t.Fatal(e)
	}
	digest := sha256.Sum256(binding)
	if confirmed {
		for rank := range f.n {
			if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairKeyConfirmed, protocol.NativePairKeyConfirmed(digest))); e != nil {
				t.Fatal(e)
			}
			if rank == 0 {
				for _, ch := range f.frames {
					select {
					case <-ch:
						t.Fatal("mesh before bilateral native confirmation")
					default:
					}
				}
			}
		}
		for rank := range f.n {
			m := f.read(t, rank, protocol.TypeNativePairMeshReady)
			b, _ := m.PayloadBytes()
			if !bytes.Equal(b, protocol.NativePairKeyConfirmed(digest)) {
				t.Fatal("changed transcript")
			}
		}
	}
	return f, s, digest
}
func meshValue(rank int, round uint8) []byte {
	if round == 0 {
		return []byte{2, 0, 0, 0}
	}
	if round == 1 {
		return bytes.Repeat([]byte{byte(rank + 20)}, 64)
	}
	return []byte{0, 0, 0, 0}
}
func TestNativePairMeshFourRoundsPreserveOrderAndGrant(t *testing.T) {
	f, s, digest := meshFixture(t, true)
	for round := uint8(0); round < 4; round++ {
		for _, rank := range []int{1, 0} {
			b, e := protocol.NativePairMeshPacket(digest, uint8(rank), round, meshValue(rank, round), false)
			if e != nil {
				t.Fatal(e)
			}
			if e = f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairMesh, b)); e != nil {
				t.Fatal(e)
			}
		}
		for rank := range f.n {
			m := f.read(t, rank, protocol.TypeNativePairMeshReply)
			b, _ := m.PayloadBytes()
			value, e := protocol.DecodeNativePairMeshPacket(b, digest, uint8(rank), round, true)
			if e != nil || !bytes.Equal(value, append(meshValue(0, round), meshValue(1, round)...)) {
				t.Fatal("rank gather/order differs", e)
			}
			if m.PrepareBeforeUnixNano != s.membership.PrepareBefore.UnixNano() || m.ExpiresAtUnixNano != s.membership.ExpiresAt.UnixNano() {
				t.Fatal("deadline restarted")
			}
		}
	}
	if f.phase(s) != VerifiedPairActive {
		t.Fatal("mesh inferred native cleanup")
	}
	f.c.mu.Lock()
	rounds := s.meshRound
	f.c.mu.Unlock()
	if rounds != 4 {
		t.Fatal("not all rounds")
	}
	f.c.Cancel(s)
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("mesh cancel released native owners")
	}
}
func TestNativePairMeshRefusesEarlyWrongContextAndSequence(t *testing.T) {
	for _, mutation := range []string{"early", "digest", "rank", "skip", "size", "duplicate", "key-repeat", "expired"} {
		t.Run(mutation, func(t *testing.T) {
			f, s, digest := meshFixture(t, mutation != "early")
			packet, _ := protocol.NativePairMeshPacket(digest, 0, 0, meshValue(0, 0), false)
			kind := protocol.TypeNativePairMesh
			switch mutation {
			case "digest":
				packet[5] ^= 1
			case "rank":
				packet[37] = 1
			case "skip":
				packet[38] = 2
			case "size":
				packet = packet[:len(packet)-1]
			case "key-repeat":
				kind = protocol.TypeNativePairKeyConfirmed
				packet = protocol.NativePairKeyConfirmed(digest)
			case "duplicate":
				if e := f.c.Handle(f.n[0], f.signed(t, s, 0, kind, packet)); e != nil {
					t.Fatal(e)
				}
			case "expired":
				f.r.mu.Lock()
				s.handle.state.membership.ExpiresAt = time.Now().Add(-time.Nanosecond)
				f.r.mu.Unlock()
			}
			if e := f.c.Handle(f.n[0], f.signed(t, s, 0, kind, packet)); e == nil {
				t.Fatal("bad mesh admitted")
			}
			if f.phase(s) != VerifiedPairQuarantined {
				t.Fatal("failed mesh freed uncertain native ownership")
			}
		})
	}
}
func TestNativePairMeshWrongKeyConfirmationNeverStartsMesh(t *testing.T) {
	f, s, digest := meshFixture(t, false)
	digest[0] ^= 1
	if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairKeyConfirmed, protocol.NativePairKeyConfirmed(digest))); e == nil {
		t.Fatal("wrong native transcript accepted")
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("invalid confirmation released owners")
	}
}
