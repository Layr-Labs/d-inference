package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestShadowUsesBoundedValidatedEndpointKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	valid := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	for _, input := range []string{"", strings.Repeat("!", 1<<20), valid + strings.Repeat("\n", 1<<20), valid} {
		reg := registry.New(logger)
		r := &protocol.RegisterMessage{PublicKey: input, AppAttestProtocol: 2}
		p := reg.Register("session", nil, r)
		st := store.NewMemory(store.Config{})
		s := &Server{store: st, logger: logger, appAttestShadow: AppAttestShadowConfig{Enabled: true, AppID: "TEST.app", Environment: "production"}}
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // No Apple/network work; inspect the constructed session only.
		if input == valid {
			// Simulate a caller retaining an unvalidated registration after the
			// registry accepted a different, valid endpoint. Only p is trusted.
			r.PublicKey = strings.Repeat("!", 1<<20)
		}
		x := s.startAppAttestShadow(ctx, p, r)
		if input == valid {
			if x == nil || x.publicKey != valid {
				t.Fatal("shadow did not use the registry's validated endpoint")
			}
		} else if x != nil {
			t.Fatalf("invalid/noncanonical endpoint started shadow: %d bytes", len(input))
		}
		reg.Disconnect(p.ID)
	}
}

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
		x := &appAttestShadowSession{s: &Server{}, provider: newCodeAttestProvider("endpoint", "se"), archive: archive, expected: "assertion", rejectReason: "verifier_busy"}
		x.handle(context.Background(), protocol.AppAttestShadowPayload{Action: "assertion", Proof: field})
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
