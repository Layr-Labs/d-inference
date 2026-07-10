package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

type cryptoContract struct {
	SchemaVersion       int                  `json:"schema_version"`
	Algorithm           string               `json:"algorithm"`
	PlaintextBase64     string               `json:"plaintext_base64"`
	PlaintextSHA256     string               `json:"plaintext_sha256"`
	SenderPrivateKey    string               `json:"sender_private_key_base64"`
	SenderPublicKey     string               `json:"sender_public_key_base64"`
	RecipientPrivateKey string               `json:"recipient_private_key_base64"`
	RecipientPublicKey  string               `json:"recipient_public_key_base64"`
	NonceBase64         string               `json:"nonce_base64"`
	Payload             e2e.EncryptedPayload `json:"payload"`
	TamperedPayload     e2e.EncryptedPayload `json:"tampered_payload"`
	StatusCanonical     statusCanonicalCases `json:"status_canonical"`
}

type statusCanonicalCases struct {
	CurrentBase64            string `json:"current_base64"`
	LegacyFalseBase64        string `json:"legacy_hypervisor_false_base64"`
	ExplicitSecurityFalseB64 string `json:"explicit_security_false_base64"`
}

func generateCrypto(_ string) (map[string][]byte, error) {
	senderPrivate, err := fixedKey("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	if err != nil {
		return nil, err
	}
	recipientPrivate, err := fixedKey("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	if err != nil {
		return nil, err
	}
	var senderPublic, recipientPublic [32]byte
	curve25519.ScalarBaseMult(&senderPublic, &senderPrivate)
	curve25519.ScalarBaseMult(&recipientPublic, &recipientPrivate)

	var nonce [24]byte
	for index := range nonce {
		nonce[index] = byte(index)
	}
	plaintext := []byte(`{"model":"contract-model","messages":[{"role":"user","content":"hello π"}]}`)
	sealed := box.Seal(nonce[:], plaintext, &nonce, &recipientPublic, &senderPrivate)
	payload := e2e.EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(senderPublic[:]),
		Ciphertext:         base64.StdEncoding.EncodeToString(sealed),
	}
	decrypted, err := e2e.DecryptWithPrivateKey(&payload, recipientPrivate)
	if err != nil || string(decrypted) != string(plaintext) {
		return nil, fmt.Errorf("self-check fixed NaCl vector: plaintext mismatch: %w", err)
	}
	tampered := append([]byte(nil), sealed...)
	tampered[len(tampered)-1] ^= 0x01

	contract := cryptoContract{
		SchemaVersion:       1,
		Algorithm:           "x25519-xsalsa20-poly1305-nacl-box",
		PlaintextBase64:     base64.StdEncoding.EncodeToString(plaintext),
		PlaintextSHA256:     digestHex(plaintext),
		SenderPrivateKey:    base64.StdEncoding.EncodeToString(senderPrivate[:]),
		SenderPublicKey:     base64.StdEncoding.EncodeToString(senderPublic[:]),
		RecipientPrivateKey: base64.StdEncoding.EncodeToString(recipientPrivate[:]),
		RecipientPublicKey:  base64.StdEncoding.EncodeToString(recipientPublic[:]),
		NonceBase64:         base64.StdEncoding.EncodeToString(nonce[:]),
		Payload:             payload,
		TamperedPayload: e2e.EncryptedPayload{
			EphemeralPublicKey: payload.EphemeralPublicKey,
			Ciphertext:         base64.StdEncoding.EncodeToString(tampered),
		},
		StatusCanonical: statusCanonicalCases{
			CurrentBase64: base64.StdEncoding.EncodeToString([]byte(
				`{"active_model_hash":"activemodel","binary_hash":"binhash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}`,
			)),
			LegacyFalseBase64: base64.StdEncoding.EncodeToString([]byte(
				`{"active_model_hash":"activemodel","binary_hash":"binhash","hypervisor_active":false,"model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}`,
			)),
			ExplicitSecurityFalseB64: base64.StdEncoding.EncodeToString([]byte(
				`{"nonce":"n","sip_enabled":false,"timestamp":"t"}`,
			)),
		},
	}
	data, err := json.MarshalIndent(contract, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal crypto contract: %w", err)
	}
	return map[string][]byte{"tests/contracts/crypto/nacl_box.json": data}, nil
}

func fixedKey(encoded string) ([32]byte, error) {
	var key [32]byte
	decoded, err := hex.DecodeString(encoded)
	if err != nil {
		return key, fmt.Errorf("decode fixed key: %w", err)
	}
	if len(decoded) != len(key) {
		return key, fmt.Errorf("fixed key has %d bytes, want %d", len(decoded), len(key))
	}
	copy(key[:], decoded)
	return key, nil
}

func digestHex(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}
