package evidence_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type capturedProofArchive struct{ evidence store.AppAttestEvidence }

func (s *capturedProofArchive) BeginAppAttestEvidence(_ context.Context, e store.AppAttestEvidence) error {
	s.evidence = e
	return nil
}
func (*capturedProofArchive) CompleteAppAttestEvidence(_ context.Context, _ string, d store.AppAttestDecision) (string, error) {
	return d.Outcome, nil
}

func TestAppAttestArchivedChecksumsIdentifyTheirExactInput(t *testing.T) {
	for _, field := range []string{"AQIDBA==", "AQID!", ""} {
		archive := &capturedProofArchive{}
		writer := evidence.NewWriter(archive, nil, &registry.Provider{ID: "p1", PublicKey: "endpoint"})
		_, err := writer.Begin(context.Background(), evidence.Input{Expected: "assertion"}, protocol.AppAttestShadowPayload{Action: "assertion", Proof: field})
		if err != nil {
			t.Fatal(err)
		}
		e := archive.evidence
		var metadata map[string]any
		if err := json.Unmarshal(e.Context, &metadata); err != nil {
			t.Fatal(err)
		}
		hash := func(b []byte) string { sum := sha256.Sum256(b); return hex.EncodeToString(sum[:]) }
		if e.ProofField != field || e.SHA256 != hash([]byte(field)) || metadata["proof_field_sha256"] != e.SHA256 || metadata["proof_field_checksum_encoding"] != "proof_field_utf8" {
			t.Fatal("original field checksum cannot be verified using its metadata")
		}
		decoded, err := base64.StdEncoding.DecodeString(field)
		if err == nil {
			if !bytes.Equal(e.Proof, decoded) || metadata["checksum_encoding"] != "base64_decoded_bytes" || metadata["proof_sha256"] != hash(decoded) || metadata["proof_decode_valid"] != true {
				t.Fatal("decoded checksum does not match its declared bytes")
			}
		} else if metadata["proof_decode_valid"] != false || metadata["proof_sha256"] != nil || metadata["checksum_encoding"] != nil || len(e.Proof) != 0 {
			t.Fatal("partial base64 output was labelled as a complete decoded proof")
		}
	}
}
