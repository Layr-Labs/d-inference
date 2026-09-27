package receipts

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func testPayload() Payload {
	return Payload{
		SchemaVersion:         1,
		Issuer:                "darkbloom",
		JobID:                 "job-123",
		WinningAttemptID:      "attempt-1",
		Nonce:                 "nonce-123",
		CallerRef:             "caller-123",
		RequestSHA256:         strings.Repeat("11", 32),
		RequestBytesSHA256:    strings.Repeat("44", 32),
		ProviderRequestSHA256: strings.Repeat("22", 32),
		RequestedModel:        "model-a",
		ResolvedModel:         "model-b",
		OutputSHA256:          strings.Repeat("33", 32),
		Status:                "completed",
		FinishReason:          "stop",
		CompletedAt:           time.Date(2030, time.January, 2, 3, 4, 5, 0, time.UTC),
		LookupExpiresAt:       time.Date(2030, time.January, 3, 3, 4, 5, 0, time.UTC),
	}
}

func testSigner(t *testing.T) (*Signer, ed25519.PublicKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	signer, err := NewSignerFromBytes("test-key", seed)
	if err != nil {
		t.Fatalf("NewSignerFromBytes: %v", err)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	return signer, privateKey.Public().(ed25519.PublicKey)
}

func TestSignerKeyIDAndPublicKeyAccessors(t *testing.T) {
	signer, expectedPublicKey := testSigner(t)
	if got := signer.KeyID(); got != "test-key" {
		t.Fatalf("KeyID() = %q, want %q", got, "test-key")
	}
	publicKey := signer.PublicKey()
	if !bytes.Equal(publicKey, expectedPublicKey) {
		t.Fatalf("PublicKey() = %x, want %x", publicKey, expectedPublicKey)
	}

	publicKey[0] ^= 0xff
	if got := signer.PublicKey(); !bytes.Equal(got, expectedPublicKey) {
		t.Fatalf("mutating PublicKey() result changed signer key: %x", got)
	}
	envelope, err := signer.Sign(testPayload())
	if err != nil {
		t.Fatalf("Sign after mutating public-key copy: %v", err)
	}
	if err := Verify(envelope, signer.PublicKey()); err != nil {
		t.Fatalf("Verify with accessor key: %v", err)
	}
}

func TestSignerAccessorsOnZeroValue(t *testing.T) {
	var signer *Signer
	if got := signer.KeyID(); got != "" {
		t.Fatalf("nil Signer.KeyID() = %q, want empty", got)
	}
	if got := signer.PublicKey(); got != nil {
		t.Fatalf("nil Signer.PublicKey() = %x, want nil", got)
	}

	zeroValue := &Signer{}
	if got := zeroValue.KeyID(); got != "" {
		t.Fatalf("zero-value Signer.KeyID() = %q, want empty", got)
	}
	if got := zeroValue.PublicKey(); got != nil {
		t.Fatalf("zero-value Signer.PublicKey() = %x, want nil", got)
	}
}

func TestKnownVectorsAndDeterministicJSON(t *testing.T) {
	if got := HashBytes([]byte("abc")); got != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("HashBytes(abc) = %q", got)
	}

	payload := testPayload()
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	const wantJSON = `{"schema_version":1,"issuer":"darkbloom","job_id":"job-123","winning_attempt_id":"attempt-1","nonce":"nonce-123","caller_ref":"caller-123","request_sha256":"1111111111111111111111111111111111111111111111111111111111111111","request_bytes_sha256":"4444444444444444444444444444444444444444444444444444444444444444","provider_request_sha256":"2222222222222222222222222222222222222222222222222222222222222222","requested_model":"model-a","resolved_model":"model-b","output_sha256":"3333333333333333333333333333333333333333333333333333333333333333","status":"completed","finish_reason":"stop","completed_at":"2030-01-02T03:04:05Z","lookup_expires_at":"2030-01-03T03:04:05Z"}`
	if string(encoded) != wantJSON {
		t.Fatalf("payload JSON changed:\n got %s\nwant %s", encoded, wantJSON)
	}

	signer, publicKey := testSigner(t)
	envelope, err := signer.Sign(payload)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if envelope.ReceiptHash != "dd7c06c87b4ae2c92f311909849b5010860db361c32dde76f6b3f62f72498e08" {
		t.Fatalf("receipt hash vector = %q", envelope.ReceiptHash)
	}
	if envelope.Signature != "6BkaWVNJFIGFmMmdPcoomsf8BVgORDjlG4siWnHXlSsVq7TqYDCus6v7gtTsd6QaPhAnoEWavKc3JPZB5n/yAg==" {
		t.Fatalf("signature vector = %q", envelope.Signature)
	}
	encodedEnvelope, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	var envelopeFields map[string]json.RawMessage
	if err := json.Unmarshal(encodedEnvelope, &envelopeFields); err != nil {
		t.Fatal(err)
	}
	if len(envelopeFields) != 4 || envelopeFields["payload"] == nil || envelopeFields["receipt_hash"] == nil || envelopeFields["key_id"] == nil || envelopeFields["signature"] == nil {
		t.Fatalf("unexpected envelope JSON fields: %s", encodedEnvelope)
	}
	var roundTrip Envelope
	if err := json.Unmarshal(encodedEnvelope, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if err := Verify(roundTrip, publicKey); err != nil {
		t.Fatalf("Verify after JSON round trip: %v", err)
	}
	if err := Verify(envelope, publicKey); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	again, err := signer.Sign(payload)
	if err != nil {
		t.Fatalf("second Sign: %v", err)
	}
	if envelope != again {
		t.Fatalf("signing was not deterministic:\n%+v\n%+v", envelope, again)
	}
}

func TestNewSignerAndFromBytesKeyForms(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)

	for name, material := range map[string][]byte{"seed": seed, "private key": privateKey} {
		t.Run(name, func(t *testing.T) {
			signer, err := NewSignerFromBytes("key-1", material)
			if err != nil {
				t.Fatalf("NewSignerFromBytes: %v", err)
			}
			envelope, err := signer.Sign(testPayload())
			if err != nil {
				t.Fatalf("Sign: %v", err)
			}
			if err := Verify(envelope, privateKey.Public().(ed25519.PublicKey)); err != nil {
				t.Fatalf("Verify: %v", err)
			}
		})
	}

	badPrivateKey := append([]byte(nil), privateKey...)
	badPrivateKey[ed25519.SeedSize] ^= 0xff
	for name, tc := range map[string]struct {
		keyID string
		key   []byte
	}{
		"empty key id":       {keyID: "", key: seed},
		"invalid key length": {keyID: "key", key: seed[:len(seed)-1]},
		"inconsistent key":   {keyID: "key", key: badPrivateKey},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := NewSignerFromBytes(tc.keyID, tc.key); err == nil {
				t.Fatal("NewSignerFromBytes accepted invalid input")
			}
		})
	}
	if _, err := NewSigner("key", privateKey[:len(privateKey)-1]); err == nil {
		t.Fatal("NewSigner accepted an invalid private-key length")
	}
}

func TestVerifyRejectsModifiedPayloadFields(t *testing.T) {
	signer, publicKey := testSigner(t)
	original, err := signer.Sign(testPayload())
	if err != nil {
		t.Fatal(err)
	}

	tests := map[string]func(*Payload){
		"schema_version":          func(p *Payload) { p.SchemaVersion = 2 },
		"issuer":                  func(p *Payload) { p.Issuer = "other-issuer" },
		"job_id":                  func(p *Payload) { p.JobID = "other-job" },
		"winning_attempt_id":      func(p *Payload) { p.WinningAttemptID = "other-attempt" },
		"nonce":                   func(p *Payload) { p.Nonce = "other-nonce" },
		"caller_ref":              func(p *Payload) { p.CallerRef = "other-caller" },
		"request_sha256":          func(p *Payload) { p.RequestSHA256 = strings.Repeat("44", 32) },
		"request_bytes_sha256":    func(p *Payload) { p.RequestBytesSHA256 = strings.Repeat("55", 32) },
		"provider_request_sha256": func(p *Payload) { p.ProviderRequestSHA256 = strings.Repeat("55", 32) },
		"requested_model":         func(p *Payload) { p.RequestedModel = "other-model" },
		"resolved_model":          func(p *Payload) { p.ResolvedModel = "other-model" },
		"output_sha256":           func(p *Payload) { p.OutputSHA256 = strings.Repeat("66", 32) },
		"status":                  func(p *Payload) { p.Status = "failed" },
		"finish_reason":           func(p *Payload) { p.FinishReason = "length" },
		"completed_at":            func(p *Payload) { p.CompletedAt = p.CompletedAt.Add(time.Second) },
		"lookup_expires_at":       func(p *Payload) { p.LookupExpiresAt = p.LookupExpiresAt.Add(time.Second) },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			tampered := original
			mutate(&tampered.Payload)
			if err := Verify(tampered, publicKey); err == nil {
				t.Fatal("Verify accepted a modified payload field")
			}
		})
	}
}

func TestVerifyRejectsTamperingAndMalformedEncoding(t *testing.T) {
	signer, publicKey := testSigner(t)
	original, err := signer.Sign(testPayload())
	if err != nil {
		t.Fatal(err)
	}

	t.Run("key id", func(t *testing.T) {
		tampered := original
		tampered.KeyID = "other-key"
		if err := Verify(tampered, publicKey); err == nil {
			t.Fatal("Verify accepted a modified key ID")
		}
	})
	t.Run("valid-looking receipt hash", func(t *testing.T) {
		tampered := original
		tampered.ReceiptHash = "0" + tampered.ReceiptHash[1:]
		if err := Verify(tampered, publicKey); err == nil {
			t.Fatal("Verify accepted a modified receipt hash")
		}
	})
	t.Run("signature bytes", func(t *testing.T) {
		tampered := original
		signature, _ := base64.StdEncoding.DecodeString(tampered.Signature)
		signature[0] ^= 1
		tampered.Signature = base64.StdEncoding.EncodeToString(signature)
		if err := Verify(tampered, publicKey); err == nil {
			t.Fatal("Verify accepted a modified signature")
		}
	})
	t.Run("malformed base64", func(t *testing.T) {
		tampered := original
		tampered.Signature = "%%%"
		if err := Verify(tampered, publicKey); err == nil {
			t.Fatal("Verify accepted malformed signature encoding")
		}
	})
	t.Run("malformed receipt hash", func(t *testing.T) {
		for _, hash := range []string{strings.Repeat("A", 64), "not-hex", strings.Repeat("0", 63)} {
			tampered := original
			tampered.ReceiptHash = hash
			if err := Verify(tampered, publicKey); err == nil {
				t.Fatalf("Verify accepted malformed hash %q", hash)
			}
		}
	})
	t.Run("wrong public key", func(t *testing.T) {
		wrong := ed25519.NewKeyFromSeed(bytesOf(0x7f, ed25519.SeedSize)).Public().(ed25519.PublicKey)
		if err := Verify(original, wrong); err == nil {
			t.Fatal("Verify accepted the wrong public key")
		}
	})
}

func TestSignAndVerifyRejectInvalidPayloads(t *testing.T) {
	signer, publicKey := testSigner(t)
	valid := testPayload()
	tests := map[string]func(*Payload){
		"schema version":           func(p *Payload) { p.SchemaVersion = 0 },
		"issuer required":          func(p *Payload) { p.Issuer = "" },
		"job id required":          func(p *Payload) { p.JobID = "" },
		"attempt id required":      func(p *Payload) { p.WinningAttemptID = "" },
		"nonce required":           func(p *Payload) { p.Nonce = "" },
		"caller ref required":      func(p *Payload) { p.CallerRef = "" },
		"request hash":             func(p *Payload) { p.RequestSHA256 = "invalid" },
		"request bytes hash":       func(p *Payload) { p.RequestBytesSHA256 = strings.Repeat("A", 64) },
		"provider request hash":    func(p *Payload) { p.ProviderRequestSHA256 = strings.Repeat("a", 63) },
		"requested model required": func(p *Payload) { p.RequestedModel = "" },
		"resolved model required":  func(p *Payload) { p.ResolvedModel = "" },
		"output hash":              func(p *Payload) { p.OutputSHA256 = strings.Repeat("g", 64) },
		"status":                   func(p *Payload) { p.Status = "pending" },
		"finish reason required":   func(p *Payload) { p.FinishReason = "" },
		"completed time required":  func(p *Payload) { p.CompletedAt = time.Time{} },
		"lookup time required":     func(p *Payload) { p.LookupExpiresAt = time.Time{} },
		"lookup after completion":  func(p *Payload) { p.LookupExpiresAt = p.CompletedAt },
		"UTC completed time":       func(p *Payload) { p.CompletedAt = p.CompletedAt.In(time.FixedZone("UTC+1", 3600)) },
		"UTC lookup time":          func(p *Payload) { p.LookupExpiresAt = p.LookupExpiresAt.In(time.FixedZone("UTC-1", -3600)) },
		"issuer upper bound":       func(p *Payload) { p.Issuer = strings.Repeat("x", 257) },
		"invalid UTF-8":            func(p *Payload) { p.Issuer = string([]byte{0xff}) },
		"serialized payload bound": func(p *Payload) {
			p.Issuer = strings.Repeat("\x00", 256)
			p.JobID = strings.Repeat("\x00", 256)
			p.WinningAttemptID = strings.Repeat("\x00", 256)
			p.Nonce = strings.Repeat("\x00", 256)
			p.CallerRef = strings.Repeat("\x00", 512)
			p.RequestedModel = strings.Repeat("\x00", 256)
			p.ResolvedModel = strings.Repeat("\x00", 256)
			p.FinishReason = strings.Repeat("\x00", 128)
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			payload := valid
			mutate(&payload)
			if _, err := signer.Sign(payload); err == nil {
				t.Fatal("Sign accepted invalid payload")
			}
			envelope, err := signer.Sign(valid)
			if err != nil {
				t.Fatal(err)
			}
			envelope.Payload = payload
			if err := Verify(envelope, publicKey); err == nil {
				t.Fatal("Verify accepted invalid payload")
			}
		})
	}
}

func TestErrorsDoNotEchoPayloadValues(t *testing.T) {
	signer, _ := testSigner(t)
	payload := testPayload()
	payload.Issuer = "private-issuer-value"
	payload.Status = "private-status-value"
	_, err := signer.Sign(payload)
	if err == nil {
		t.Fatal("Sign accepted an invalid status")
	}
	if strings.Contains(err.Error(), payload.Issuer) || strings.Contains(err.Error(), payload.Status) {
		t.Fatalf("validation error echoed payload values: %v", err)
	}
}

func bytesOf(value byte, size int) []byte {
	return bytes.Repeat([]byte{value}, size)
}
