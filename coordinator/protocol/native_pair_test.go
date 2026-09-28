package protocol

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestNativePairPublicBytesMatchQualifiedSwiftPrelude(t *testing.T) {
	b, e := os.ReadFile("testdata/native_pair_public_vector.json")
	if e != nil {
		t.Fatal(e)
	}
	var vector struct {
		Common, Binding, OuterSigningBytes string
		Starts, Hellos, PublicKeys         []string
	}
	if e = json.Unmarshal(b, &vector); e != nil {
		t.Fatal(e)
	}
	c := NativeAuthorizationCommon{MembershipGeneration: 7, NativePolicyGeneration: 11, Schedule: 2, MaximumTransportFrame: 4136, MaximumPlaintext: 4096, MaximumRecords: 64, MaximumCumulativePlaintext: 262144}
	for i := range c.Epoch {
		c.Epoch[i] = byte(i + 1)
	}
	hashes := []*[32]byte{&c.MembershipTranscriptSHA256, &c.ApprovedNativeBindingSHA256, &c.PlanSHA256, &c.ArtifactSHA256, &c.NativeRuntimeSHA256, &c.CapabilitySHA256, &c.ResourcePolicySHA256, &c.ProfileSHA256}
	for i, h := range hashes {
		*h = sha256.Sum256([]byte(fmt.Sprint("fixture-native-field-", i)))
	}
	common, e := c.Canonical()
	if e != nil || hex.EncodeToString(common) != vector.Common {
		t.Fatal("common differs from actual qualified Swift/OpenSSL vector")
	}
	var starts [2]NativeAuthorizationStart
	var hellos [2][]byte
	for rank := range starts {
		s := NativeAuthorizationStart{Common: c, Rank: uint8(rank)}
		s.OwnerIncarnation[15] = byte(100 + 10*rank)
		s.LeaseID[15] = byte(101 + 10*rank)
		s.LaunchID[15] = byte(102 + 10*rank)
		starts[rank] = s
		encoded, e := s.Canonical()
		if e != nil || hex.EncodeToString(encoded) != vector.Starts[rank] {
			t.Fatal("start bytes differ")
		}
		hellos[rank], _ = hex.DecodeString(vector.Hellos[rank])
		if ValidateNativeAuthorizationHello(hellos[rank], s) != nil {
			t.Fatal("qualified hello refused")
		}
	}
	binding, e := NativeAuthorizationBinding(hellos, starts)
	if e != nil || hex.EncodeToString(binding) != vector.Binding {
		t.Fatal("native key binding differs")
	}
	m := NativePairMessage{Type: TypeNativePairHello, Version: 1, MemberNonce: strings.Repeat("11", 32), Epoch: strings.Repeat("22", 16), Generation: 7, Sequence: 9, Payload: base64.StdEncoding.EncodeToString(hellos[0])}
	signing, e := m.SigningBytes()
	if e != nil || hex.EncodeToString(signing) != vector.OuterSigningBytes {
		t.Fatal("outer signature bytes differ from independent Python assembly")
	}
	hellos[0][5+len(common)+5] ^= 1
	if ValidateNativeAuthorizationHello(hellos[0], starts[0]) == nil {
		t.Fatal("substituted expected context admitted")
	}
}
func TestNativePairClosedPublicEnvelope(t *testing.T) {
	m := NativePairMessage{Type: TypeNativePairHello, Version: 1, MemberNonce: strings.Repeat("1", 64), Epoch: strings.Repeat("2", 32), Generation: 7, Sequence: 9, Payload: "AA=="}
	b, _ := json.Marshal(m)
	if _, e := DecodeNativePairMessage(b); e != nil {
		t.Fatal(e)
	}
	cases := [][]byte{
		append(append([]byte(nil), b[:len(b)-1]...), []byte(`,"sequence":9}`)...),
		append(append([]byte(nil), b[:len(b)-1]...), []byte(`,"unknown":1}`)...),
		[]byte(strings.Replace(string(b), `"sequence":9`, `"sequence":1.0`, 1)),
		[]byte(strings.Replace(string(b), `"sequence":9`, `"sequence":18446744073709551616`, 1)),
		[]byte(strings.Replace(string(b), `"version":1`, `"version":2`, 1)),
		[]byte(strings.Replace(string(b), `"payload":"AA=="`, `"payload":null`, 1)),
		[]byte(strings.Replace(string(b), `"payload":"AA=="`, `"payload":"AB=="`, 1)),
		[]byte(strings.Replace(string(b), TypeNativePairHello, "native_pair_unknown", 1)),
		append(append([]byte(nil), b...), b...),
	}
	for i, b := range cases {
		if _, e := DecodeNativePairMessage(b); e == nil {
			t.Fatalf("malformed case %d admitted", i)
		}
	}
}
