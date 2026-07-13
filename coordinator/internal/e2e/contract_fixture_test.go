package e2e

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type cryptoFixture struct {
	SchemaVersion       int              `json:"schema_version"`
	PlaintextBase64     string           `json:"plaintext_base64"`
	PlaintextSHA256     string           `json:"plaintext_sha256"`
	RecipientPrivateKey string           `json:"recipient_private_key_base64"`
	Payload             EncryptedPayload `json:"payload"`
	TamperedPayload     EncryptedPayload `json:"tampered_payload"`
}

func TestNaClBoxContractFixture(t *testing.T) {
	path := filepath.Join("..", "..", "..", "tests", "contracts", "crypto", "nacl_box.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fixture cryptoFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if fixture.SchemaVersion != 1 {
		t.Fatalf("schema version = %d, want 1", fixture.SchemaVersion)
	}
	plaintext, err := base64.StdEncoding.DecodeString(fixture.PlaintextBase64)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(plaintext)
	if got := hex.EncodeToString(digest[:]); got != fixture.PlaintextSHA256 {
		t.Fatalf("plaintext digest = %s, want %s", got, fixture.PlaintextSHA256)
	}
	privateBytes, err := base64.StdEncoding.DecodeString(fixture.RecipientPrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	if len(privateBytes) != 32 {
		t.Fatalf("recipient private key has %d bytes", len(privateBytes))
	}
	var privateKey [32]byte
	copy(privateKey[:], privateBytes)
	decrypted, err := DecryptWithPrivateKey(&fixture.Payload, privateKey)
	if err != nil {
		t.Fatalf("decrypt fixed vector: %v", err)
	}
	if string(decrypted) != string(plaintext) {
		t.Fatalf("decrypted plaintext mismatch\nwant: %q\ngot:  %q", plaintext, decrypted)
	}
	if _, err := DecryptWithPrivateKey(&fixture.TamperedPayload, privateKey); err == nil {
		t.Fatal("tampered vector decrypted successfully")
	}
}
