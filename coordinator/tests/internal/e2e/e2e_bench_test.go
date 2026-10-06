package e2e_test

import (
	"crypto/rand"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

func makePayload(size int) []byte {
	data := make([]byte, size)
	rand.Read(data)
	return data
}

func BenchmarkEncrypt_Small(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(100) // 100 bytes
	session, _ := production.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for range b.N {
		_, _ = production.Encrypt(plaintext, recipientPub, session)
	}
}

func BenchmarkEncrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(4096) // 4KB
	session, _ := production.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for range b.N {
		_, _ = production.Encrypt(plaintext, recipientPub, session)
	}
}

func BenchmarkEncrypt_Large(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(65536) // 64KB
	session, _ := production.GenerateSessionKeys()
	var recipientPub [32]byte
	rand.Read(recipientPub[:])

	b.ResetTimer()
	for range b.N {
		_, _ = production.Encrypt(plaintext, recipientPub, session)
	}
}

// setupEncryptedPayload creates a valid encrypted payload for decrypt benchmarks.
func setupEncryptedPayload(size int) (*production.EncryptedPayload, *production.SessionKeys) {
	plaintext := makePayload(size)
	sender, _ := production.GenerateSessionKeys()
	recipient, _ := production.GenerateSessionKeys()
	payload, _ := production.Encrypt(plaintext, recipient.PublicKey, sender)
	// To decrypt, we need the recipient's session and the sender's public key
	// is embedded in the payload. So we return the recipient session.
	return payload, recipient
}

func BenchmarkDecrypt_Small(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(100)

	b.ResetTimer()
	for range b.N {
		_, _ = production.Decrypt(payload, session)
	}
}

func BenchmarkDecrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(4096)

	b.ResetTimer()
	for range b.N {
		_, _ = production.Decrypt(payload, session)
	}
}

func BenchmarkDecrypt_Large(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(65536)

	b.ResetTimer()
	for range b.N {
		_, _ = production.Decrypt(payload, session)
	}
}

func BenchmarkEncryptDecryptRoundtrip(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(4096) // 4KB representative payload
	sender, _ := production.GenerateSessionKeys()
	recipient, _ := production.GenerateSessionKeys()

	b.ResetTimer()
	for range b.N {
		payload, err := production.Encrypt(plaintext, recipient.PublicKey, sender)
		if err != nil {
			b.Fatal(err)
		}
		_, err = production.Decrypt(payload, recipient)
		if err != nil {
			b.Fatal(err)
		}
	}
}
