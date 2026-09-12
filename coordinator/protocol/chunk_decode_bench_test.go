package protocol

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"testing"
)

// Benchmarks for the per-token inference_response_chunk frame decode — the
// single hottest decode in the coordinator (one WebSocket frame per streamed
// token, ~117K/s at peak). The fixture mirrors the Swift provider's wire shape:
// JSONEncoder with .sortedKeys, so "type" is the LAST top-level key and the
// nested payload keys are alphabetical too.

// benchSwiftChunkFrame returns a Swift-shaped chunk frame of roughly the
// production size (~620 B): a UUID request id, a 32-byte X25519 key and a
// ~340-byte NaCl box (nonce || ciphertext), both base64.
func benchSwiftChunkFrame() []byte {
	eph := make([]byte, 32)
	ct := make([]byte, 340)
	if _, err := rand.Read(eph); err != nil {
		panic(err)
	}
	if _, err := rand.Read(ct); err != nil {
		panic(err)
	}
	return []byte(swiftShapedChunkFrame(
		"0f3a9c1e-6b7d-4a2e-9c5f-1d2e3f4a5b6c",
		base64.StdEncoding.EncodeToString(eph),
		base64.StdEncoding.EncodeToString(ct),
	))
}

// swiftShapedChunkFrame renders the exact key order the Swift provider emits
// (JSONEncoder .sortedKeys, .withoutEscapingSlashes; empty data omitted).
func swiftShapedChunkFrame(requestID, ephemeralPublicKey, ciphertext string) string {
	return `{"encrypted_data":{"ciphertext":"` + ciphertext +
		`","ephemeral_public_key":"` + ephemeralPublicKey +
		`"},"request_id":"` + requestID +
		`","type":"` + TypeInferenceResponseChunk + `"}`
}

// The read loop's decode as it stood before the hand-written scanner:
// json.Unmarshal into ProviderMessage (outer validation pass + UnmarshalJSON).
// Comparable to A6's BenchmarkChunk_1_FrameUnmarshal.
func BenchmarkChunkFrame_ProviderMessage_Unmarshal(b *testing.B) {
	frame := benchSwiftChunkFrame()
	b.ReportAllocs()
	b.SetBytes(int64(len(frame)))
	for i := 0; i < b.N; i++ {
		var pm ProviderMessage
		if err := json.Unmarshal(frame, &pm); err != nil {
			b.Fatal(err)
		}
	}
}

// Permanent generic baseline: encoding/json straight into the concrete struct
// (what the fallback path costs).
func BenchmarkChunkFrame_Concrete_Unmarshal(b *testing.B) {
	frame := benchSwiftChunkFrame()
	b.ReportAllocs()
	b.SetBytes(int64(len(frame)))
	for i := 0; i < b.N; i++ {
		var msg InferenceResponseChunkMessage
		if err := json.Unmarshal(frame, &msg); err != nil {
			b.Fatal(err)
		}
	}
}

// The read loop's decode as it stands now: DecodeProviderMessage, which skips
// encoding/json's outer validation pass and takes the chunk fast path.
func BenchmarkChunkFrame_DecodeProviderMessage(b *testing.B) {
	frame := benchSwiftChunkFrame()
	b.ReportAllocs()
	b.SetBytes(int64(len(frame)))
	for i := 0; i < b.N; i++ {
		var pm ProviderMessage
		if err := DecodeProviderMessage(frame, &pm); err != nil {
			b.Fatal(err)
		}
	}
}

// The scanner alone.
func BenchmarkChunkFrame_Scan(b *testing.B) {
	frame := benchSwiftChunkFrame()
	b.ReportAllocs()
	b.SetBytes(int64(len(frame)))
	for i := 0; i < b.N; i++ {
		if _, ok := scanChunkFrame(frame); !ok {
			b.Fatal("fast path not taken")
		}
	}
}
