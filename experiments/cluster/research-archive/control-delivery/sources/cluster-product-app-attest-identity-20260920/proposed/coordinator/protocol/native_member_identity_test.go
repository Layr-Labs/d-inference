package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

const nativeIdentityTestKey = "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="

func nativeIdentityFixture(kind NativeMemberIdentityKind) NativeMemberIdentity {
	p := NativeMemberIdentity{Kind: kind, ProviderID: "member", ControlPublicKey: nativeIdentityTestKey, ProcessPublicKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=", BinarySHA256: [32]byte{}, MetallibSHA256: [32]byte{}, ReleasePolicyGeneration: 7}
	for i := range p.BinarySHA256 {
		p.BinarySHA256[i] = 2
		p.MetallibSHA256[i] = 3
	}
	if kind == NativeIdentityLegacyMDA {
		p.DeviceSerial = "serial"
	} else {
		p.AccountID = "account"
		p.MachineID = "machine"
		p.CredentialID = "credential"
		p.ProofSessionID = "proof"
	}
	return p
}
func TestNativeIdentityCanonicalCrossLanguageVectors(t *testing.T) {
	for _, x := range []struct {
		kind     NativeMemberIdentityKind
		expected string
	}{{NativeIdentityLegacyMDA, "44424e49440101000000066d656d626572000000584247735830664c684c454a482b4c7a6d35574f6b51504a33413332424c65737a6f5053684f5558596d4d4b57542b4e43347634616635754f352b744b66412b654669764f4d3164724d56374f79375a416144652f5566553d0000002c415145424151454241514542415145424151454241514542415145424151454241514542415145424151453d0202020202020202020202020202020202020202020202020202020202020202030303030303030303030303030303030303030303030303030303030303030300000000000000070000000673657269616c"}, {NativeIdentityAppAttest, "44424e49440102000000066d656d626572000000584247735830664c684c454a482b4c7a6d35574f6b51504a33413332424c65737a6f5053684f5558596d4d4b57542b4e43347634616635754f352b744b66412b654669764f4d3164724d56374f79375a416144652f5566553d0000002c415145424151454241514542415145424151454241514542415145424151454241514542415145424151453d020202020202020202020202020202020202020202020202020202020202020203030303030303030303030303030303030303030303030303030303030303030000000000000007000000076163636f756e74000000076d616368696e650000000a63726564656e7469616c0000000570726f6f66"}} {
		p := nativeIdentityFixture(x.kind)
		raw, err := p.Canonical()
		if err != nil || hex.EncodeToString(raw) != x.expected {
			t.Fatalf("canonical: %v", err)
		}
		got, err := DecodeNativeMemberIdentity(raw)
		if err != nil || got != p {
			t.Fatalf("roundtrip: %v", err)
		}
	}
}
func TestNativeIdentityRejectsTruncationTrailingAndUnknownKinds(t *testing.T) {
	for _, kind := range []NativeMemberIdentityKind{NativeIdentityLegacyMDA, NativeIdentityAppAttest} {
		raw, _ := nativeIdentityFixture(kind).Canonical()
		for n := 0; n < len(raw); n++ {
			if _, err := DecodeNativeMemberIdentity(raw[:n]); err == nil {
				t.Fatalf("accepted prefix %d", n)
			}
		}
		for _, bad := range [][]byte{append(append([]byte{}, raw...), 0), bytes.Repeat([]byte{1}, 1025)} {
			if _, err := DecodeNativeMemberIdentity(bad); err == nil {
				t.Fatal("accepted surplus")
			}
		}
		raw[6] = 3
		if _, err := DecodeNativeMemberIdentity(raw); err == nil {
			t.Fatal("unknown kind")
		}
	}
}
func TestNativeIdentityRejectsCrossKindAndUnprovenFields(t *testing.T) {
	changes := []func(*NativeMemberIdentity){func(p *NativeMemberIdentity) { p.DeviceSerial = "invented" }, func(p *NativeMemberIdentity) { p.AccountID = "" }, func(p *NativeMemberIdentity) { p.MachineID = "" }, func(p *NativeMemberIdentity) { p.CredentialID = "" }, func(p *NativeMemberIdentity) { p.ProofSessionID = "" }, func(p *NativeMemberIdentity) { p.ProviderID = strings.Repeat("a", 129) }, func(p *NativeMemberIdentity) { p.ProviderID = "bad\n" }, func(p *NativeMemberIdentity) { p.ProviderID = string([]byte{255}) }, func(p *NativeMemberIdentity) { p.ControlPublicKey = p.ProcessPublicKey }, func(p *NativeMemberIdentity) {
		p.ProcessPublicKey = base64.StdEncoding.EncodeToString(make([]byte, 32))
	}, func(p *NativeMemberIdentity) { p.BinarySHA256 = [32]byte{} }, func(p *NativeMemberIdentity) { p.MetallibSHA256 = [32]byte{} }, func(p *NativeMemberIdentity) { p.ReleasePolicyGeneration = 0 }}
	for i, change := range changes {
		p := nativeIdentityFixture(NativeIdentityAppAttest)
		change(&p)
		if _, err := p.Canonical(); err == nil {
			t.Fatalf("accepted invalid field %d", i)
		}
	}
	p := nativeIdentityFixture(NativeIdentityLegacyMDA)
	p.AccountID = "invented"
	if p.Validate() == nil {
		t.Fatal("cross-kind metadata accepted")
	}
}
func TestNativeIdentitySignerEncodingCannotEvadeIdentity(t *testing.T) {
	p := nativeIdentityFixture(NativeIdentityAppAttest)
	want, _ := p.SigningKeyIdentity()
	raw, _ := base64.StdEncoding.DecodeString(p.ControlPublicKey)
	p.ControlPublicKey = base64.StdEncoding.EncodeToString(raw[1:])
	got, err := p.SigningKeyIdentity()
	if err != nil || got != want {
		t.Fatal("point alias changed exclusion key")
	}
	p.ControlPublicKey = base64.StdEncoding.EncodeToString(make([]byte, 65))
	if _, err := p.SigningKeyIdentity(); err == nil {
		t.Fatal("invalid curve point")
	}
}
func TestNativeIdentityBindsCredentialProofConnectionAndGeneration(t *testing.T) {
	p := nativeIdentityFixture(NativeIdentityAppAttest)
	base, _ := p.Canonical()
	for _, change := range []func(*NativeMemberIdentity){func(p *NativeMemberIdentity) { p.ProviderID = "replacement" }, func(p *NativeMemberIdentity) { p.CredentialID = "new" }, func(p *NativeMemberIdentity) { p.ProofSessionID = "new" }, func(p *NativeMemberIdentity) { p.ReleasePolicyGeneration++ }} {
		q := p
		change(&q)
		raw, err := q.Canonical()
		if err != nil || bytes.Equal(raw, base) {
			t.Fatal("binding omitted")
		}
	}
}
