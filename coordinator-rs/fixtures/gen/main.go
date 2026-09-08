// Command gen writes the cross-language golden vectors consumed by the Rust
// darkbloom-protocol crate tests (coordinator-rs/crates/protocol).
//
// Run from the repository root:
//
//	go run ./coordinator-rs/fixtures/gen
//
// It emits, under coordinator-rs/fixtures/vectors/:
//
//   - json_v1/*.json      — Go-marshaled instances of every v1 wire message
//     (populated + zero-value variants) so the Rust
//     types pin field names, omitempty behavior, and
//     null-vs-absent semantics against encoding/json.
//   - nacl_box/vectors.json      — deterministic NaCl Box vectors (fixed
//     keys, fixed nonces) plus box.Precompute
//     shared keys.
//   - sealed_sender/vectors.json — sender→coordinator sealed-transport
//     envelope vectors (request, response, SSE).
//   - signing/vectors.json       — P-256 ECDSA vectors: challenge
//     signatures, canonical status payloads, and
//     a raw signed attestation blob.
//
// Everything key- or nonce-shaped is derived from fixed strings via SHA-256,
// so regenerating the box/sealed vectors is byte-stable. ECDSA signatures are
// randomized per run (the verification inputs are what matter); the checked-in
// files are the fixture of record.
//
// This package may import coordinator/protocol and coordinator/attestation,
// but nothing under coordinator/internal/.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"golang.org/x/crypto/curve25519"
)

const vectorsDir = "coordinator-rs/fixtures/vectors"

func main() {
	if _, err := os.Stat("coordinator-rs"); err != nil {
		log.Fatal("run from the repository root: go run ./coordinator-rs/fixtures/gen")
	}
	writeJSONV1Goldens(filepath.Join(vectorsDir, "json_v1"))
	writeBoxVectors(filepath.Join(vectorsDir, "nacl_box"))
	writeSealedSenderVectors(filepath.Join(vectorsDir, "sealed_sender"))
	writeSigningVectors(filepath.Join(vectorsDir, "signing"))
	fmt.Println("vectors written to", vectorsDir)
}

// writeFile marshals v (compact, encoding/json semantics — the point of the
// exercise) and writes it.
func writeFile(dir, name string, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		log.Fatalf("marshal %s: %v", name, err)
	}
	writeRaw(dir, name, data)
}

func writeRaw(dir, name string, data []byte) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Fatalf("mkdir %s: %v", dir, err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		log.Fatalf("write %s: %v", path, err)
	}
}

// deriveBytes gives len deterministic bytes from a label.
func deriveBytes(label string, n int) []byte {
	out := make([]byte, 0, n)
	counter := 0
	for len(out) < n {
		sum := sha256.Sum256(fmt.Appendf(nil, "%s-%d", label, counter))
		out = append(out, sum[:]...)
		counter++
	}
	return out[:n]
}

// x25519Keypair derives a deterministic X25519 keypair from a label. The raw
// private bytes are stored unclamped (both Go's box and Rust's crypto_box
// clamp at use).
func x25519Keypair(label string) (priv, pub [32]byte) {
	copy(priv[:], deriveBytes(label, 32))
	p, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		log.Fatalf("derive public key for %s: %v", label, err)
	}
	copy(pub[:], p)
	return priv, pub
}
