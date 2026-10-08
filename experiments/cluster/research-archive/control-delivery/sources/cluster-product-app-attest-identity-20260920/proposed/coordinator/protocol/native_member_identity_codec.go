package protocol

import (
	"bytes"
	"encoding/binary"
)

const NativeMemberIdentityMaximumBytes = 1024

func (p NativeMemberIdentity) Canonical() ([]byte, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	b := append([]byte("DBNID\x01"), byte(p.Kind))
	add := func(s string) { b = binary.BigEndian.AppendUint32(b, uint32(len(s))); b = append(b, s...) }
	for _, s := range []string{p.ProviderID, p.ControlPublicKey, p.ProcessPublicKey} {
		add(s)
	}
	b = append(b, p.BinarySHA256[:]...)
	b = append(b, p.MetallibSHA256[:]...)
	b = binary.BigEndian.AppendUint64(b, p.ReleasePolicyGeneration)
	if p.Kind == NativeIdentityLegacyMDA {
		add(p.DeviceSerial)
	} else {
		for _, s := range []string{p.AccountID, p.MachineID, p.CredentialID, p.ProofSessionID} {
			add(s)
		}
	}
	if len(b) > NativeMemberIdentityMaximumBytes {
		return nil, ErrNativeMemberIdentity
	}
	return b, nil
}

func DecodeNativeMemberIdentity(raw []byte) (NativeMemberIdentity, error) {
	var p NativeMemberIdentity
	if len(raw) > NativeMemberIdentityMaximumBytes {
		return p, ErrNativeMemberIdentity
	}
	b := raw
	take := func(n int) []byte {
		if n < 0 || n > len(b) {
			return nil
		}
		v := b[:n]
		b = b[n:]
		return v
	}
	text := func() string {
		n := take(4)
		if n == nil || binary.BigEndian.Uint32(n) > 128 {
			return ""
		}
		return string(take(int(binary.BigEndian.Uint32(n))))
	}
	if !bytes.Equal(take(6), []byte("DBNID\x01")) {
		return p, ErrNativeMemberIdentity
	}
	kind := take(1)
	if kind == nil {
		return p, ErrNativeMemberIdentity
	}
	p.Kind = NativeMemberIdentityKind(kind[0])
	p.ProviderID, p.ControlPublicKey, p.ProcessPublicKey = text(), text(), text()
	copy(p.BinarySHA256[:], take(32))
	copy(p.MetallibSHA256[:], take(32))
	generation := take(8)
	if generation == nil {
		return p, ErrNativeMemberIdentity
	}
	p.ReleasePolicyGeneration = binary.BigEndian.Uint64(generation)
	switch p.Kind {
	case NativeIdentityLegacyMDA:
		p.DeviceSerial = text()
	case NativeIdentityAppAttest:
		p.AccountID, p.MachineID, p.CredentialID, p.ProofSessionID = text(), text(), text(), text()
	default:
		return NativeMemberIdentity{}, ErrNativeMemberIdentity
	}
	encoded, err := p.Canonical()
	if err != nil || len(b) != 0 || !bytes.Equal(encoded, raw) {
		return NativeMemberIdentity{}, ErrNativeMemberIdentity
	}
	return p, nil
}
