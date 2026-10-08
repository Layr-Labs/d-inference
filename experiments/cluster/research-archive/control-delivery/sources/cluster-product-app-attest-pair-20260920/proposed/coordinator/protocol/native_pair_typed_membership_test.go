package protocol

import (
	"encoding/hex"
	"testing"
)

func nativeTypedMembershipFixture() NativePairTypedMembership {
	m := NativePairTypedMembership{Generation: 9, Model: "model", Suite: "aes256gcm-hkdf-sha256-v1", PrepareBeforeUnixNano: 100, ExpiresAtUnixNano: 200,
		Members: [2]NativeMemberIdentity{nativeIdentityFixture(NativeIdentityLegacyMDA), nativeIdentityFixture(NativeIdentityAppAttest)}}
	for i := range m.Epoch {
		m.Epoch[i] = 1
	}
	for i := range m.PlanSHA256 {
		m.PlanSHA256[i] = 4
		m.ProposedRuntimeBindingSHA256[i] = 5
	}
	return m
}
func TestNativePairTypedMembershipCrossLanguageCommitments(t *testing.T) {
	m := nativeTypedMembershipFixture()
	got, err := m.Digest()
	if err != nil || hex.EncodeToString(got[:]) != "05472f9f7e8b3b84281dfeab49fc7b97d9d33d7b28548e53ee53bfd2c5566e17" {
		t.Fatal("mixed canonical digest", err)
	}
	m.Members[0] = nativeIdentityFixture(NativeIdentityAppAttest)
	got, err = m.Digest()
	if err != nil || hex.EncodeToString(got[:]) != "4d440df367756b3ca9ddab0028140f74b77a6971614dd8afccfdb85de81906af" {
		t.Fatal("AA canonical digest", err)
	}
}
func TestNativePairTypedMembershipBindsRolesProofAndNativePolicy(t *testing.T) {
	changes := []func(*NativePairTypedMembership){
		func(m *NativePairTypedMembership) { m.Epoch[0] ^= 1 }, func(m *NativePairTypedMembership) { m.Generation++ },
		func(m *NativePairTypedMembership) { m.Model = "other" }, func(m *NativePairTypedMembership) { m.PlanSHA256[0] ^= 1 },
		func(m *NativePairTypedMembership) { m.ProposedRuntimeBindingSHA256[0] ^= 1 }, func(m *NativePairTypedMembership) { m.PrepareBeforeUnixNano++ },
		func(m *NativePairTypedMembership) { m.ExpiresAtUnixNano++ }, func(m *NativePairTypedMembership) { m.Members[0], m.Members[1] = m.Members[1], m.Members[0] },
		func(m *NativePairTypedMembership) { m.Members[1].AccountID = "other" }, func(m *NativePairTypedMembership) { m.Members[1].MachineID = "other" },
		func(m *NativePairTypedMembership) { m.Members[1].ProofSessionID = "other" }, func(m *NativePairTypedMembership) { m.Members[1].CredentialID = "other" },
	}
	original, _ := nativeTypedMembershipFixture().Digest()
	for _, change := range changes {
		m := nativeTypedMembershipFixture()
		change(&m)
		got, err := m.Digest()
		if err != nil || got == original {
			t.Fatal("unbound typed membership field", err)
		}
	}
}
func TestNativePairTypedMembershipRefusesLegacyVersionConfusion(t *testing.T) {
	changes := []func(*NativePairTypedMembership){func(m *NativePairTypedMembership) { m.Members[1] = m.Members[0] },
		func(m *NativePairTypedMembership) { m.Epoch = [16]byte{} }, func(m *NativePairTypedMembership) { m.Generation = 0 },
		func(m *NativePairTypedMembership) { m.Suite = "unknown" }, func(m *NativePairTypedMembership) { m.PrepareBeforeUnixNano = 0 },
		func(m *NativePairTypedMembership) { m.ExpiresAtUnixNano = 99 }, func(m *NativePairTypedMembership) { m.PlanSHA256 = [32]byte{} },
		func(m *NativePairTypedMembership) { m.Members[1].DeviceSerial = "invented" }}
	for _, change := range changes {
		m := nativeTypedMembershipFixture()
		change(&m)
		if _, err := m.Digest(); err == nil {
			t.Fatal("accepted invalid or all-legacy v2")
		}
	}
}
