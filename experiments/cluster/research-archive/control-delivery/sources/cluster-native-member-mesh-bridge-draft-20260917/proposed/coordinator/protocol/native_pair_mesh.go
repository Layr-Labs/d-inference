package protocol

import "bytes"

// Public bootstrap metadata only. Inference bytes and arbitrary collectives are
// not legal here. The transcript is the SHA256 of A's exact canonical binding.
// The signed outer frame independently binds rank's connection/epoch/generation.
func NativePairKeyConfirmed(transcript [32]byte) []byte {
	b := append([]byte("DBNK\x01"), transcript[:]...)
	return b
}

func ValidateNativePairMeshContribution(round uint8, contribution []byte) error {
	switch round {
	case 0:
		if bytes.Equal(contribution, []byte{2, 0, 0, 0}) {
			return nil
		}
	case 1:
		if len(contribution) == 64 {
			return nil
		}
	case 2, 3:
		if bytes.Equal(contribution, []byte{0, 0, 0, 0}) {
			return nil
		}
	}
	return ErrNativePairFrame
}

// Contribution/reply use distinct tags. The exact native ABI sizes remove a
// caller-controlled allocation/length field. Round never wraps past three.
func NativePairMeshPacket(transcript [32]byte, rank, round uint8, value []byte, reply bool) ([]byte, error) {
	if rank > 1 || round > 3 {
		return nil, ErrNativePairFrame
	}
	n := 4
	if round == 1 {
		n = 64
	}
	if reply {
		if len(value) != n*2 {
			return nil, ErrNativePairFrame
		}
		for r := 0; r < 2; r++ {
			if ValidateNativePairMeshContribution(round, value[r*n:(r+1)*n]) != nil {
				return nil, ErrNativePairFrame
			}
		}
	} else if ValidateNativePairMeshContribution(round, value) != nil {
		return nil, ErrNativePairFrame
	}
	tag := []byte("DBNM\x01")
	if reply {
		tag = []byte("DBNG\x01")
	}
	b := append(tag, transcript[:]...)
	b = append(b, rank, round)
	return append(b, value...), nil
}

func DecodeNativePairMeshPacket(packet []byte, transcript [32]byte, rank, round uint8, reply bool) ([]byte, error) {
	if len(packet) < 39 {
		return nil, ErrNativePairFrame
	}
	value := packet[39:]
	expected, e := NativePairMeshPacket(transcript, rank, round, value, reply)
	if e != nil || !bytes.Equal(expected, packet) {
		return nil, ErrNativePairFrame
	}
	return append([]byte(nil), value...), nil
}
