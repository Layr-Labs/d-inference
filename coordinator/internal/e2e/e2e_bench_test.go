package e2e

import (
	"crypto/rand"
	"testing"
)

func makePayload(tb testing.TB, size int) []byte {
	tb.Helper()
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		tb.Fatalf("fill payload: %v", err)
	}
	return data
}

func BenchmarkEncrypt_Small(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(b, 100) // 100 bytes
	session := generateSessionKeys(b)
	recipientPub, _ := generateBoxKeys(b)

	b.ResetTimer()
	for range b.N {
		if _, err := Encrypt(plaintext, *recipientPub, session); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkEncrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(b, 4096) // 4KB
	session := generateSessionKeys(b)
	recipientPub, _ := generateBoxKeys(b)

	b.ResetTimer()
	for range b.N {
		if _, err := Encrypt(plaintext, *recipientPub, session); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkEncrypt_Large(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(b, 65536) // 64KB
	session := generateSessionKeys(b)
	recipientPub, _ := generateBoxKeys(b)

	b.ResetTimer()
	for range b.N {
		if _, err := Encrypt(plaintext, *recipientPub, session); err != nil {
			b.Fatal(err)
		}
	}
}

// setupEncryptedPayload creates a valid encrypted payload for decrypt benchmarks.
func setupEncryptedPayload(tb testing.TB, size int) (*EncryptedPayload, *SessionKeys) {
	tb.Helper()
	plaintext := makePayload(tb, size)
	sender := generateSessionKeys(tb)
	recipient := generateSessionKeys(tb)
	payload := encryptForTest(tb, plaintext, recipient.PublicKey, sender)
	return payload, recipient
}

func BenchmarkDecrypt_Small(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(b, 100)

	b.ResetTimer()
	for range b.N {
		if _, err := Decrypt(payload, session); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkDecrypt_Medium(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(b, 4096)

	b.ResetTimer()
	for range b.N {
		if _, err := Decrypt(payload, session); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkDecrypt_Large(b *testing.B) {
	b.ReportAllocs()
	payload, session := setupEncryptedPayload(b, 65536)

	b.ResetTimer()
	for range b.N {
		if _, err := Decrypt(payload, session); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkEncryptDecryptRoundtrip(b *testing.B) {
	b.ReportAllocs()
	plaintext := makePayload(b, 4096) // 4KB representative payload
	sender := generateSessionKeys(b)
	recipient := generateSessionKeys(b)

	b.ResetTimer()
	for range b.N {
		payload, err := Encrypt(plaintext, recipient.PublicKey, sender)
		if err != nil {
			b.Fatal(err)
		}
		_, err = Decrypt(payload, recipient)
		if err != nil {
			b.Fatal(err)
		}
	}
}
