package protocol

import (
	"encoding/json"
	"testing"
)

func TestPrivateV2ChunkEnvelopeDecodesTypedMetadata(t *testing.T) {
	wire := []byte(`{"type":"private_chunk_v2","version":"private_v2","request_id":"r1","sequence":4,"terminal":true,"nonce":"AAECAwQFBgcICQoL","ciphertext":"opaque","usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8},"failure_code":"generation_failure","status_code":502}`)
	var envelope ProviderMessage
	if err := json.Unmarshal(wire, &envelope); err != nil {
		t.Fatal(err)
	}
	chunk, ok := envelope.Payload.(*PrivateChunkV2Message)
	if !ok || chunk.Type != TypePrivateChunkV2 || chunk.Sequence != 4 || !chunk.Terminal ||
		chunk.Usage == nil || chunk.Usage.TotalTokens != 8 ||
		chunk.FailureCode != "generation_failure" || chunk.StatusCode != 502 {
		t.Fatalf("decoded private chunk = %#v", envelope.Payload)
	}
}

func TestPrivateV2RequestWireContainsNoPlaintextBody(t *testing.T) {
	request := PrivateRequestV2Message{
		Type: TypePrivateRequestV2, Version: "private_v2", LeaseID: "lease",
		RequestID: "request", RouteID: "route", Model: "model",
		Endpoint: "messages", Deadline: "2030-01-02T03:04:35Z",
		TranscriptDigest: "digest", ProcessCertificateDigest: "certificate",
		ReleaseBinaryHash: "release", ModelManifestHash: "manifest",
		ReleaseGeneration: 8, ModelGeneration: 9, KDFSalt: "salt",
		ClientPublicKey: "client", Nonce: "nonce", Ciphertext: "opaque",
	}
	wire, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, exists := decoded["body"]; exists {
		t.Fatal("private-v2 provider request exposed a plaintext body field")
	}
	if decoded["ciphertext"] != "opaque" || decoded["kdf_salt"] != "salt" {
		t.Fatalf("opaque request fields changed: %s", wire)
	}
}
