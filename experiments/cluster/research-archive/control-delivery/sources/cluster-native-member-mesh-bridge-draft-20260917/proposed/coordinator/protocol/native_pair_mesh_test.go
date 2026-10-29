package protocol

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestNativePairMeshIndependentPublicVector(t *testing.T) {
	var digest [32]byte
	for i := range digest {
		digest[i] = byte(i)
	}
	expected, _ := hex.DecodeString("44424e4d01000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f010002000000")
	actual, e := NativePairMeshPacket(digest, 1, 0, []byte{2, 0, 0, 0}, false)
	if e != nil || !bytes.Equal(actual, expected) {
		t.Fatal("canonical public vector differs", e)
	}
	key, _ := hex.DecodeString("44424e4b01000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	if !bytes.Equal(NativePairKeyConfirmed(digest), key) {
		t.Fatal("key-confirmed vector differs")
	}
	for i := range expected {
		bad := append([]byte(nil), expected...)
		bad[i] ^= 0x80
		if _, e := DecodeNativePairMeshPacket(bad, digest, 1, 0, false); e == nil {
			t.Fatal("changed vector admitted", i)
		}
	}
}
func TestNativePairMeshClosedSizesAndDirections(t *testing.T) {
	var digest [32]byte
	digest[0] = 1
	for round := uint8(0); round < 4; round++ {
		value := []byte{0, 0, 0, 0}
		if round == 0 {
			value[0] = 2
		}
		if round == 1 {
			value = bytes.Repeat([]byte{7}, 64)
		}
		for rank := uint8(0); rank < 2; rank++ {
			packet, e := NativePairMeshPacket(digest, rank, round, value, false)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = DecodeNativePairMeshPacket(packet, digest, rank, round, true); e == nil {
				t.Fatal("reflection")
			}
			for _, bad := range [][]byte{packet[:len(packet)-1], append(append([]byte(nil), packet...), 0)} {
				if _, e = DecodeNativePairMeshPacket(bad, digest, rank, round, false); e == nil {
					t.Fatal("length")
				}
			}
			gathered := append(append([]byte(nil), value...), value...)
			reply, e := NativePairMeshPacket(digest, rank, round, gathered, true)
			if e != nil {
				t.Fatal(e)
			}
			if b, e := DecodeNativePairMeshPacket(reply, digest, rank, round, true); e != nil || !bytes.Equal(b, gathered) {
				t.Fatal("reply")
			}
		}
	}
	if _, e := NativePairMeshPacket(digest, 2, 0, []byte{2, 0, 0, 0}, false); e == nil {
		t.Fatal("rank")
	}
	if _, e := NativePairMeshPacket(digest, 0, 4, []byte{0, 0, 0, 0}, false); e == nil {
		t.Fatal("round")
	}
}
