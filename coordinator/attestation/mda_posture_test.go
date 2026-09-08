package attestation

import (
	"encoding/asn1"
	"testing"
)

func TestApplePostureEncodingsFailClosed(t *testing.T) {
	encode := func(v any) []byte {
		b, err := asn1.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	for _, tc := range []struct {
		name string
		data []byte
		good bool
	}{
		{"SIP enabled", encode(0), true},
		{"SIP disabled", encode(1), false},
		{"SIP partially disabled", encode(0x803), false},
		{"negative", encode(-1), false},
		{"boolean", encode(true), false},
		{"missing", nil, false},
		{"trailing bytes", append(encode(0), 0), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got, _ := parseSIPMeasurement(tc.data); got != tc.good {
				t.Fatalf("got %v want %v", got, tc.good)
			}
		})
	}
	for _, value := range []string{"Full Security", "Reduced Security", "Permissive Security", "", "full", "Unknown"} {
		if got, _ := parseSecureBootMeasurement(encode(value)); got != (value == "Full Security") {
			t.Fatalf("boot %q decoded as %v", value, got)
		}
	}
	for _, data := range [][]byte{nil, encode(true), encode(0), append(encode("Full Security"), 0)} {
		if full, _ := parseSecureBootMeasurement(data); full {
			t.Fatal("malformed boot posture accepted")
		}
	}
}
