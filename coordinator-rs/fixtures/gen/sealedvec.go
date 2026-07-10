package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"

	"golang.org/x/crypto/nacl/box"
)

// Sealed-sender vectors mirror coordinator/api/sender_encryption.go. That
// package keeps its envelope structs private, so the shapes are reproduced
// here with the exact same JSON keys; the Rust test decodes them with the
// crate's own envelope types, which pins the shape both ways.

type sealedRequestEnvelope struct {
	KID                string `json:"kid"`
	EphemeralPublicKey string `json:"ephemeral_public_key"`
	Ciphertext         string `json:"ciphertext"`
}

type sealedResponseEnvelope struct {
	KID        string `json:"kid"`
	Ciphertext string `json:"ciphertext"`
}

type sealedSenderVectors struct {
	CoordinatorPrivateKeyHex string `json:"coordinator_private_key_hex"`
	CoordinatorPublicKeyB64  string `json:"coordinator_public_key_b64"`
	// First 16 hex chars of SHA-256(coordinator public key)
	// (coordinator/internal/e2e/coordinator_key.go).
	KID                 string `json:"kid"`
	ClientPrivateKeyHex string `json:"client_private_key_hex"`
	ClientPublicKeyB64  string `json:"client_public_key_b64"`

	Request struct {
		PlaintextHex string                `json:"plaintext_hex"`
		NonceHex     string                `json:"nonce_hex"`
		Envelope     sealedRequestEnvelope `json:"envelope"`
	} `json:"request"`

	Response struct {
		PlaintextHex string                 `json:"plaintext_hex"`
		NonceHex     string                 `json:"nonce_hex"`
		Envelope     sealedResponseEnvelope `json:"envelope"`
	} `json:"response"`

	SSE struct {
		EventHex string `json:"event_hex"`
		NonceHex string `json:"nonce_hex"`
		Line     string `json:"line"`
	} `json:"sse"`
}

func writeSealedSenderVectors(dir string) {
	coordPriv, coordPub := x25519Keypair("darkbloom-fixture-coordinator")
	clientPriv, clientPub := x25519Keypair("darkbloom-fixture-client")

	pubSum := sha256.Sum256(coordPub[:])
	kid := hex.EncodeToString(pubSum[:8])

	var v sealedSenderVectors
	v.CoordinatorPrivateKeyHex = hex.EncodeToString(coordPriv[:])
	v.CoordinatorPublicKeyB64 = base64.StdEncoding.EncodeToString(coordPub[:])
	v.KID = kid
	v.ClientPrivateKeyHex = hex.EncodeToString(clientPriv[:])
	v.ClientPublicKeyB64 = base64.StdEncoding.EncodeToString(clientPub[:])

	// Request: sealed by the client TO the coordinator.
	reqBody := []byte(`{"model":"qwen-3-8b","messages":[{"role":"user","content":"sealed hello"}],"stream":true}`)
	var reqNonce [24]byte
	copy(reqNonce[:], deriveBytes("darkbloom-fixture-sealed-request-nonce", 24))
	reqSealed := box.Seal(reqNonce[:], reqBody, &reqNonce, &coordPub, &clientPriv)
	v.Request.PlaintextHex = hex.EncodeToString(reqBody)
	v.Request.NonceHex = hex.EncodeToString(reqNonce[:])
	v.Request.Envelope = sealedRequestEnvelope{
		KID:                kid,
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(clientPub[:]),
		Ciphertext:         base64.StdEncoding.EncodeToString(reqSealed),
	}

	// Response: sealed by the coordinator TO the client's ephemeral key.
	respBody := []byte(`{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":"sealed reply"}}]}`)
	var respNonce [24]byte
	copy(respNonce[:], deriveBytes("darkbloom-fixture-sealed-response-nonce", 24))
	respSealed := box.Seal(respNonce[:], respBody, &respNonce, &clientPub, &coordPriv)
	v.Response.PlaintextHex = hex.EncodeToString(respBody)
	v.Response.NonceHex = hex.EncodeToString(respNonce[:])
	v.Response.Envelope = sealedResponseEnvelope{
		KID:        kid,
		Ciphertext: base64.StdEncoding.EncodeToString(respSealed),
	}

	// SSE: one sealed event line, including the upstream `data: ` prefix in
	// the sealed payload (sender_encryption.go seals everything between
	// \n\n boundaries).
	event := []byte(`data: {"choices":[{"delta":{"content":"hi"}}]}`)
	var sseNonce [24]byte
	copy(sseNonce[:], deriveBytes("darkbloom-fixture-sealed-sse-nonce", 24))
	sseSealed := box.Seal(sseNonce[:], event, &sseNonce, &clientPub, &coordPriv)
	v.SSE.EventHex = hex.EncodeToString(event)
	v.SSE.NonceHex = hex.EncodeToString(sseNonce[:])
	v.SSE.Line = fmt.Sprintf("data: %s\n\n", base64.StdEncoding.EncodeToString(sseSealed))

	writeFile(dir, "vectors.json", v)
}
