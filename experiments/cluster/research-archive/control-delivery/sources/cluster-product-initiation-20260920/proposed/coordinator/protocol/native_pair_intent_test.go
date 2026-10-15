package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

func intentFixture() NativePairIntent {
	var p NativePairIntent
	p.ClusterID = "cluster-fixture"
	p.ApprovalID = "approved-fixture"
	p.MemberIDs = [2]string{"member-0", "member-1"}
	p.Rank = 0
	p.LifetimeSeconds = 300
	for i := 0; i < 32; i++ {
		p.PolicySHA256[i] = 0x11
		p.SignerSHA256[0][i] = 0x22
		p.SignerSHA256[1][i] = 0x33
	}
	return p
}
func TestNativePairIntentCanonicalAndSeparateSigningDomain(t *testing.T) {
	p := intentFixture()
	raw, e := p.Canonical()
	if e != nil {
		t.Fatal(e)
	}
	decoded, e := DecodeNativePairIntent(raw)
	if e != nil || decoded != p {
		t.Fatal(e)
	}
	// Independently assembled vector is also pinned by the Swift fixture.
	const expected = "44424e4943010000000f636c75737465722d6669787475726500000010617070726f7665642d666978747572651111111111111111111111111111111111111111111111111111111111111111000000086d656d6265722d302222222222222222222222222222222222222222222222222222222222222222000000086d656d6265722d313333333333333333333333333333333333333333333333333333333333333333000000012c"
	if hex.EncodeToString(raw) != expected {
		t.Fatalf("canonical intent differs: %x", raw)
	}
	m := NativePairIntentMessage{Type: TypeNativePairIntent, Version: 1, MemberNonce: strings.Repeat("a", 64), Sequence: 1, Payload: base64.StdEncoding.EncodeToString(raw)}
	signed, e := m.SigningBytes()
	if e != nil || !bytes.HasPrefix(signed, []byte("darkbloom/coordinator-native-pair/configuration-intent/v1\x00")) {
		t.Fatal(e)
	}
	if bytes.HasPrefix(signed, []byte("darkbloom/coordinator-native-pair/member-message/v1\x00")) {
		t.Fatal("grant response signing domain reused")
	}
}
func TestNativePairIntentRejectsBoundsTruncationAndAmbiguousEnvelope(t *testing.T) {
	p := intentFixture()
	raw, _ := p.Canonical()
	for n := 0; n < len(raw); n++ {
		if _, e := DecodeNativePairIntent(raw[:n]); e == nil {
			t.Fatalf("truncation %d accepted", n)
		}
	}
	if _, e := DecodeNativePairIntent(append(append([]byte{}, raw...), 0)); e == nil {
		t.Fatal("trailing data")
	}
	for _, change := range []func(*NativePairIntent){func(p *NativePairIntent) { p.Rank = 2 }, func(p *NativePairIntent) { p.LifetimeSeconds = 301 }, func(p *NativePairIntent) { p.LifetimeSeconds = 0 }, func(p *NativePairIntent) { p.MemberIDs[1] = p.MemberIDs[0] }, func(p *NativePairIntent) { p.SignerSHA256[1] = p.SignerSHA256[0] }, func(p *NativePairIntent) { p.PolicySHA256 = [32]byte{} }} {
		x := p
		change(&x)
		if _, e := x.Canonical(); e == nil {
			t.Fatal("invalid canonical shape")
		}
	}
	m := NativePairIntentMessage{Type: TypeNativePairIntent, Version: 1, MemberNonce: strings.Repeat("a", 64), Sequence: 1, Payload: base64.StdEncoding.EncodeToString(raw), Signature: base64.StdEncoding.EncodeToString(make([]byte, 8))}
	wire, _ := json.Marshal(m)
	if _, e := DecodeNativePairIntentMessage(wire); e != nil {
		t.Fatal(e)
	}
	for _, bad := range [][]byte{append(wire, '\n'), []byte(strings.Replace(string(wire), `"version":1`, `"version":1,"version":1`, 1)), []byte(strings.Replace(string(wire), `"version":1`, `"version":null`, 1)), []byte(strings.Replace(string(wire), `"version":1`, `"version":1,"approved":true`, 1)), []byte(strings.Replace(string(wire), `"sequence":1`, `"sequence":0`, 1))} {
		if _, e := DecodeNativePairIntentMessage(bad); e == nil {
			t.Fatal("ambiguous wire accepted")
		}
	}
}
