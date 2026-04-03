package billing

import (
	"crypto/rand"
	"testing"
)

func BenchmarkBase58Encode(b *testing.B) {
	b.ReportAllocs()
	// Typical 32-byte Solana public key
	data := make([]byte, 32)
	rand.Read(data)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = base58Encode(data)
	}
}

func BenchmarkBase58Decode(b *testing.B) {
	b.ReportAllocs()
	// A realistic Solana address (USDC mint)
	addr := USDCMintMainnet // "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = base58Decode(addr)
	}
}

func BenchmarkDeriveATA(b *testing.B) {
	b.ReportAllocs()
	// Decode wallet and mint once for setup.
	wallet := make([]byte, 32)
	rand.Read(wallet)
	mint, _ := base58Decode(USDCMintMainnet)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = deriveATA(wallet, mint)
	}
}
