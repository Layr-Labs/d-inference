package main

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"

	"golang.org/x/crypto/nacl/box"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// boxVector is one deterministic Go-sealed NaCl Box vector. shared_key_hex is
// box.Precompute(recipientPub, senderPriv) == box.Precompute(senderPub,
// recipientPriv): asserting equality against it in Rust, plus a Rust
// deterministic re-seal producing identical ciphertext, proves both interop
// directions without running Go inside the Rust tests.
type boxVector struct {
	Name                   string                    `json:"name"`
	SenderPrivateKeyHex    string                    `json:"sender_private_key_hex"`
	SenderPublicKeyB64     string                    `json:"sender_public_key_b64"`
	RecipientPrivateKeyHex string                    `json:"recipient_private_key_hex"`
	RecipientPublicKeyB64  string                    `json:"recipient_public_key_b64"`
	NonceHex               string                    `json:"nonce_hex"`
	PlaintextHex           string                    `json:"plaintext_hex"`
	Payload                protocol.EncryptedPayload `json:"payload"`
	SharedKeyHex           string                    `json:"shared_key_hex"`
}

func writeBoxVectors(dir string) {
	senderPriv, senderPub := x25519Keypair("darkbloom-fixture-box-sender")
	recipientPriv, recipientPub := x25519Keypair("darkbloom-fixture-box-recipient")

	var shared [32]byte
	box.Precompute(&shared, &recipientPub, &senderPriv)

	// Symmetry sanity: both derivations must agree before we emit anything.
	var sharedReverse [32]byte
	box.Precompute(&sharedReverse, &senderPub, &recipientPriv)
	if shared != sharedReverse {
		panic("box.Precompute asymmetry — vector generation is broken")
	}

	plaintexts := []struct {
		name string
		data []byte
	}{
		{"empty", []byte{}},
		{"one_byte", []byte{0x42}},
		{"json_body", []byte(`{"model":"qwen-3-8b-4bit","messages":[{"role":"user","content":"hello from Go"}],"stream":true}`)},
		{"utf8_multibyte", []byte("こんにちは世界 🌍 émojis — ünïcödé")},
		{"four_kib", bytes.Repeat([]byte{0xA5, 0x5A, 0x00, 0xFF}, 1024)},
	}

	vectors := make([]boxVector, 0, len(plaintexts))
	for _, pt := range plaintexts {
		var nonce [24]byte
		copy(nonce[:], deriveBytes("darkbloom-fixture-box-nonce-"+pt.name, 24))

		sealed := box.Seal(nonce[:], pt.data, &nonce, &recipientPub, &senderPriv)
		vectors = append(vectors, boxVector{
			Name:                   pt.name,
			SenderPrivateKeyHex:    hex.EncodeToString(senderPriv[:]),
			SenderPublicKeyB64:     base64.StdEncoding.EncodeToString(senderPub[:]),
			RecipientPrivateKeyHex: hex.EncodeToString(recipientPriv[:]),
			RecipientPublicKeyB64:  base64.StdEncoding.EncodeToString(recipientPub[:]),
			NonceHex:               hex.EncodeToString(nonce[:]),
			PlaintextHex:           hex.EncodeToString(pt.data),
			Payload: protocol.EncryptedPayload{
				EphemeralPublicKey: base64.StdEncoding.EncodeToString(senderPub[:]),
				Ciphertext:         base64.StdEncoding.EncodeToString(sealed),
			},
			SharedKeyHex: hex.EncodeToString(shared[:]),
		})
	}

	writeFile(dir, "vectors.json", vectors)
}
