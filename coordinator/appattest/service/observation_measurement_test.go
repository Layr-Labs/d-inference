package service

import (
	"bytes"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/appattest"
)

func TestShadowObservationDistinguishesTruncatedAppleCodeHash(t *testing.T) {
	category, type2, type1 := uint32(6), uint8(2), uint8(1)
	for _, tc := range []struct {
		name, wantComparison, wantFormat string
		measurement                      *appattest.Key
	}{
		{"short SHA256", "truncated_measurement_pending_qualification", "sha256_prefix_20", &appattest.Key{ValidationCategory: &category, CodeDirectoryType: &type2, CodeDirectoryHash: bytes.Repeat([]byte{0x42}, 20)}},
		{"full SHA256", "matched", "sha256_full_32", &appattest.Key{ValidationCategory: &category, CodeDirectoryType: &type2, CodeDirectoryHash: bytes.Repeat([]byte{0x42}, 32)}},
		{"SHA1", "metadata_missing", "", &appattest.Key{ValidationCategory: &category, CodeDirectoryType: &type1, CodeDirectoryHash: bytes.Repeat([]byte{0x42}, 20)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var observed map[string]any
			s := &Service{emitEvent: func(fields map[string]any) { observed = fields }}
			x := &Session{s: s, provider: newSessionProvider("endpoint", "se"), version: "0.9.9"}
			x.observe("assertion", "verified", tc.measurement)
			if observed["metadata_comparison"] != tc.wantComparison {
				t.Fatalf("metadata comparison = %v, want %s", observed["metadata_comparison"], tc.wantComparison)
			}
			if tc.wantFormat != "" && observed["attested_code_directory_hash_format"] != tc.wantFormat {
				t.Fatalf("hash format = %v, want %s", observed["attested_code_directory_hash_format"], tc.wantFormat)
			}
		})
	}
}
