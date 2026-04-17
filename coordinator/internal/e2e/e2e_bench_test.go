package e2e_test

import (
	"crypto/rand"
	"testing"

	"github.com/eigeninference/coordinator/internal/e2e"
)

func makePayload(size int) []byte {
	data := make([]byte, size)
	rand.Read(data)
	return data
}

func BenchmarkEncrypt_Small(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(100) // 100 bytes
	session, _ := e2e.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Encrypt(plaintext, recipientPub, session)
	}
}

func BenchmarkEncrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(4096) // 4KB
	session, _ := e2e.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Encrypt(plaintext, recipientPub, session)
	}
}

func BenchmarkEncrypt_Large(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(65536) // 64KB
	session, _ := e2e.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Encrypt(plaintext, recipientPub, session)
	}
}

// setupEncryptedPayload creates a valid encrypted payload for decrypt benchmarks.
func setupEncryptedPayload(size int) (*e2e.EncryptedPayload, *e2e.SessionKeys) {
	plaintext := makePayload(size)
	sender, _ := e2e.GenerateSessionKeys()
	recipient, _ := e2e.GenerateSessionKeys()
	payload, _ := e2e.Encrypt(plaintext, recipient.PublicKey, sender)
	// To decrypt, we need the recipient's session and the sender's public key
	// is embedded in the payload. So we return the recipient session.
	return payload, recipient
}

func BenchmarkDecrypt_Small(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(100)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Decrypt(payload, session)
	}
}

func BenchmarkDecrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(4096)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Decrypt(payload, session)
	}
}

func BenchmarkDecrypt_Large(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(65536)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = e2e.Decrypt(payload, session)
	}
}

func BenchmarkEncryptDecryptRoundtrip(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(4096) // 4KB representative payload
	sender, _ := e2e.GenerateSessionKeys()
	recipient, _ := e2e.GenerateSessionKeys()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		payload, err := e2e.Encrypt(plaintext, recipient.PublicKey, sender)
		if err != nil {
			b.Fatal(err)
		}
		_, err = e2e.Decrypt(payload, recipient)
		if err != nil {
			b.Fatal(err)
		}
	}
}
