package protocol

import (
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"unicode/utf8"
)

type NativeMemberIdentityKind uint8

const (
	NativeIdentityLegacyMDA NativeMemberIdentityKind = 1
	NativeIdentityAppAttest NativeMemberIdentityKind = 2
)

var ErrNativeMemberIdentity = errors.New("invalid native member identity binding")

// A coordinator-observed identity description, not a grant, lease or peer
// assertion. App Attest machine identity is account-scoped continuity, not an
// Apple-certified hardware serial. Unused variant fields MUST remain empty.
type NativeMemberIdentity struct {
	Kind                                               NativeMemberIdentityKind
	ProviderID, ControlPublicKey, ProcessPublicKey     string
	BinarySHA256, MetallibSHA256                       [32]byte
	ReleasePolicyGeneration                            uint64
	DeviceSerial                                       string
	AccountID, MachineID, CredentialID, ProofSessionID string
}

func nativeIdentityText(s string) bool {
	if len(s) == 0 || len(s) > 128 || !utf8.ValidString(s) {
		return false
	}
	for _, c := range s {
		if c < 33 || c == 127 {
			return false
		}
	}
	return true
}

func canonicalIdentityKey(s string, size int) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) != size || base64.StdEncoding.EncodeToString(b) != s {
		return nil, false
	}
	var nonzero byte
	for _, v := range b {
		nonzero |= v
	}
	return b, nonzero != 0
}

// Existing registration accepts raw XY and X9.63. Preserve the actual signed
// representation in the transcript, but normalize point identity for device
// exclusion so an alternate encoding cannot evade a retained signer hold.
func (p NativeMemberIdentity) SigningKeyIdentity() ([32]byte, error) {
	return NativeControlSigningKeyIdentity(p.ControlPublicKey)
}

// Normalized exclusion key only; the signed wire representation stays unchanged.
func NativeControlSigningKeyIdentity(key string) ([32]byte, error) {
	b, ok := canonicalIdentityKey(key, 65)
	if !ok {
		b, ok = canonicalIdentityKey(key, 64)
		if !ok {
			return [32]byte{}, ErrNativeMemberIdentity
		}
		b = append([]byte{4}, b...)
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), b)
	if x == nil || y == nil {
		return [32]byte{}, ErrNativeMemberIdentity
	}
	return sha256.Sum256(elliptic.Marshal(elliptic.P256(), x, y)), nil
}

func (p NativeMemberIdentity) Validate() error {
	if !nativeIdentityText(p.ProviderID) || p.BinarySHA256 == [32]byte{} || p.MetallibSHA256 == [32]byte{} || p.ReleasePolicyGeneration == 0 {
		return ErrNativeMemberIdentity
	}
	if _, ok := canonicalIdentityKey(p.ProcessPublicKey, 32); !ok {
		return ErrNativeMemberIdentity
	}
	if _, err := p.SigningKeyIdentity(); err != nil {
		return err
	}
	switch p.Kind {
	case NativeIdentityLegacyMDA:
		if !nativeIdentityText(p.DeviceSerial) || p.AccountID != "" || p.MachineID != "" || p.CredentialID != "" || p.ProofSessionID != "" {
			return ErrNativeMemberIdentity
		}
	case NativeIdentityAppAttest:
		if p.DeviceSerial != "" || !nativeIdentityText(p.AccountID) || !nativeIdentityText(p.MachineID) || !nativeIdentityText(p.CredentialID) || !nativeIdentityText(p.ProofSessionID) {
			return ErrNativeMemberIdentity
		}
	default:
		return ErrNativeMemberIdentity
	}
	return nil
}
