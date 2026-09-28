package protocol

import (
	"bytes"
	"encoding/binary"
)

// Exact public-byte mirror of ClusterNativeAuthorization{Common,Start,Hello}
// from the native prelude. These records carry no authority by themselves.
type NativeAuthorizationCommon struct {
	Epoch                                                                               [16]byte
	MembershipGeneration, NativePolicyGeneration                                        uint64
	MembershipTranscriptSHA256, ApprovedNativeBindingSHA256, PlanSHA256, ArtifactSHA256 [32]byte
	NativeRuntimeSHA256, CapabilitySHA256, ResourcePolicySHA256, ProfileSHA256          [32]byte
	Schedule                                                                            uint8 // 1 serial, 2 one-chunk lookahead
	MaximumTransportFrame, MaximumPlaintext                                             uint32
	MaximumRecords, MaximumCumulativePlaintext                                          uint64
}
type NativeAuthorizationStart struct {
	Common                              NativeAuthorizationCommon
	Rank                                uint8
	OwnerIncarnation, LeaseID, LaunchID [16]byte
}

func (c NativeAuthorizationCommon) Canonical() ([]byte, error) {
	if c.Epoch == [16]byte{} || c.MembershipGeneration == 0 || c.NativePolicyGeneration == 0 || (c.Schedule != 1 && c.Schedule != 2) || c.MaximumPlaintext == 0 || c.MaximumPlaintext > 16*1024*1024 || c.MaximumTransportFrame < c.MaximumPlaintext+40 || c.MaximumTransportFrame > 16*1024*1024+40 || c.MaximumRecords == 0 || c.MaximumRecords > 1048576 || c.MaximumCumulativePlaintext == 0 || c.MaximumCumulativePlaintext > 4*1024*1024*1024 {
		return nil, ErrNativePairFrame
	}
	b := []byte("darkbloom/native-authorization/common/v1\x00")
	b = append(b, c.Epoch[:]...)
	b = binary.BigEndian.AppendUint64(b, c.MembershipGeneration)
	b = binary.BigEndian.AppendUint64(b, c.NativePolicyGeneration)
	for _, h := range [][32]byte{c.MembershipTranscriptSHA256, c.ApprovedNativeBindingSHA256, c.PlanSHA256, c.ArtifactSHA256, c.NativeRuntimeSHA256, c.CapabilitySHA256, c.ResourcePolicySHA256, c.ProfileSHA256} {
		if h == [32]byte{} {
			return nil, ErrNativePairFrame
		}
		b = append(b, h[:]...)
	}
	b = append(b, 1, 1, c.Schedule)
	b = binary.BigEndian.AppendUint32(b, c.MaximumTransportFrame)
	b = binary.BigEndian.AppendUint32(b, c.MaximumPlaintext)
	b = binary.BigEndian.AppendUint64(b, c.MaximumRecords)
	b = binary.BigEndian.AppendUint64(b, c.MaximumCumulativePlaintext)
	return b, nil
}
func (s NativeAuthorizationStart) Canonical() ([]byte, error) {
	if s.Rank > 1 || s.OwnerIncarnation == [16]byte{} || s.LeaseID == [16]byte{} || s.LaunchID == [16]byte{} {
		return nil, ErrNativePairFrame
	}
	c, e := s.Common.Canonical()
	if e != nil {
		return nil, e
	}
	b := append([]byte("DBNS\x01"), c...)
	b = append(b, s.Rank)
	b = append(b, s.OwnerIncarnation[:]...)
	b = append(b, s.LeaseID[:]...)
	b = append(b, s.LaunchID[:]...)
	return b, nil
}

// A hello may only repeat the coordinator's exact expected start, followed by a
// canonical nonzero X25519 public key. Small-order rejection also occurs in the
// native's actual DH operation; the coordinator never computes a shared key.
func ValidateNativeAuthorizationHello(payload []byte, expected NativeAuthorizationStart) error {
	s, e := expected.Canonical()
	if e != nil {
		return e
	}
	prefix := append([]byte("DBNH\x01"), s...)
	if len(payload) != len(prefix)+32 || !bytes.Equal(payload[:len(prefix)], prefix) {
		return ErrNativePairFrame
	}
	key := payload[len(prefix):]
	nonzero := false
	for _, v := range key {
		nonzero = nonzero || v != 0
	}
	if !nonzero {
		return ErrNativePairFrame
	}
	prime := [32]byte{0xed}
	for i := 1; i < 31; i++ {
		prime[i] = 0xff
	}
	prime[31] = 0x7f
	for i := 31; i >= 0; i-- {
		if key[i] < prime[i] {
			return nil
		}
		if key[i] > prime[i] {
			return ErrNativePairFrame
		}
	}
	return ErrNativePairFrame
}
func NativeAuthorizationBinding(hello [2][]byte, start [2]NativeAuthorizationStart) ([]byte, error) {
	if start[0].Rank != 0 || start[1].Rank != 1 || start[0].Common != start[1].Common || start[0].OwnerIncarnation == start[1].OwnerIncarnation || start[0].LeaseID == start[1].LeaseID || start[0].LaunchID == start[1].LaunchID {
		return nil, ErrNativePairFrame
	}
	for i := range hello {
		if ValidateNativeAuthorizationHello(hello[i], start[i]) != nil {
			return nil, ErrNativePairFrame
		}
	}
	if bytes.Equal(hello[0][len(hello[0])-32:], hello[1][len(hello[1])-32:]) {
		return nil, ErrNativePairFrame
	}
	b := append([]byte("DBNB\x01"), hello[0]...)
	return append(b, hello[1]...), nil
}
