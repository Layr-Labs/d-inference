package protocol

import (
	"crypto/sha256"
	"encoding/binary"
	"unicode/utf8"
)

// V2 is a coordinator-produced commitment, not peer evidence. Native Start's
// existing 32-byte membership field carries this digest unchanged through
// prepare, commit, key establishment and release. All-legacy v1 stays separate.
type NativePairTypedMembership struct {
	Epoch                                    [16]byte
	Generation                               uint64
	Model, Suite                             string
	PlanSHA256, ProposedRuntimeBindingSHA256 [32]byte
	PrepareBeforeUnixNano, ExpiresAtUnixNano int64
	Members                                  [2]NativeMemberIdentity
}

func (m NativePairTypedMembership) Digest() ([32]byte, error) {
	if m.Epoch == [16]byte{} || m.Generation == 0 || m.Model == "" || len(m.Model) > 512 || !utf8.ValidString(m.Model) ||
		m.Suite != "aes256gcm-hkdf-sha256-v1" || m.PlanSHA256 == [32]byte{} || m.ProposedRuntimeBindingSHA256 == [32]byte{} ||
		m.PrepareBeforeUnixNano <= 0 || m.ExpiresAtUnixNano < m.PrepareBeforeUnixNano ||
		(m.Members[0].Kind != NativeIdentityAppAttest && m.Members[1].Kind != NativeIdentityAppAttest) {
		return [32]byte{}, ErrNativeMemberIdentity
	}
	b := append([]byte("darkbloom/coordinator-pair-membership/v2\x00"), m.Epoch[:]...)
	b = binary.BigEndian.AppendUint64(b, m.Generation)
	put := func(value []byte) { b = binary.BigEndian.AppendUint32(b, uint32(len(value))); b = append(b, value...) }
	put([]byte(m.Model))
	b = append(b, m.PlanSHA256[:]...)
	b = append(b, m.ProposedRuntimeBindingSHA256[:]...)
	put([]byte(m.Suite))
	b = binary.BigEndian.AppendUint64(b, uint64(m.PrepareBeforeUnixNano))
	b = binary.BigEndian.AppendUint64(b, uint64(m.ExpiresAtUnixNano))
	for rank, member := range m.Members {
		canonical, err := member.Canonical()
		if err != nil {
			return [32]byte{}, err
		}
		b = append(b, byte(rank))
		put(canonical)
	}
	return sha256.Sum256(b), nil
}
