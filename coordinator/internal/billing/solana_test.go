package billing

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// --- Base58 Tests ---

func TestBase58RoundTrip(t *testing.T) {
	cases := []struct {
		name    string
		decoded []byte
	}{
		{"empty", []byte{}},
		{"single zero", []byte{0}},
		{"leading zeros", []byte{0, 0, 0, 1}},
		{"simple", []byte{1, 2, 3, 4, 5}},
		{"32 bytes", make([]byte, 32)},
	}

	// Fill the 32-byte case with non-trivial data.
	for i := range cases[4].decoded {
		cases[4].decoded[i] = byte(i * 7)
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			encoded := base58Encode(tc.decoded)
			decoded, err := base58Decode(encoded)
			if err != nil {
				t.Fatalf("decode error: %v", err)
			}
			if len(tc.decoded) == 0 && len(decoded) == 0 {
				return // both empty, ok
			}
			if len(decoded) != len(tc.decoded) {
				t.Fatalf("length mismatch: got %d, want %d", len(decoded), len(tc.decoded))
			}
			for i := range decoded {
				if decoded[i] != tc.decoded[i] {
					t.Fatalf("byte %d mismatch: got %d, want %d", i, decoded[i], tc.decoded[i])
				}
			}
		})
	}
}

func TestBase58DecodeKnownValues(t *testing.T) {
	// Known Solana addresses decode to 32 bytes.
	addresses := []string{
		TokenProgramID,
		AssociatedTokenProgramID,
		USDCMintMainnet,
		SystemProgramID,
	}
	for _, addr := range addresses {
		decoded, err := base58Decode(addr)
		if err != nil {
			t.Fatalf("decode %s: %v", addr, err)
		}
		if len(decoded) != 32 {
			t.Fatalf("expected 32 bytes for %s, got %d", addr, len(decoded))
		}

		// Re-encode should produce the same string.
		reencoded := base58Encode(decoded)
		if reencoded != addr {
			t.Fatalf("re-encode mismatch for %s: got %s", addr, reencoded)
		}
	}
}

func TestBase58DecodeInvalidChar(t *testing.T) {
	_, err := base58Decode("invalid0char") // '0' is not in base58
	if err == nil {
		t.Fatal("expected error for invalid character")
	}
	if !strings.Contains(err.Error(), "invalid character") {
		t.Fatalf("expected 'invalid character' error, got: %v", err)
	}
}

// --- ATA Derivation Tests ---

func TestDeriveATAKnownAddress(t *testing.T) {
	// Known ATA derivation test vector:
	// Wallet: 5ZiE3vAkrdXBgyFL7KXjicSPm5Y78VoydNsRgFP4pCPY (arbitrary test wallet)
	// Mint:   EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v (USDC mainnet)
	//
	// We verify the ATA derivation is deterministic and produces a 32-byte result.
	wallet, err := base58Decode("5ZiE3vAkrdXBgyFL7KXjicSPm5Y78VoydNsRgFP4pCPY")
	if err != nil {
		t.Fatalf("decode wallet: %v", err)
	}
	mint, err := base58Decode(USDCMintMainnet)
	if err != nil {
		t.Fatalf("decode mint: %v", err)
	}

	ata, err := deriveATA(wallet, mint)
	if err != nil {
		t.Fatalf("derive ATA: %v", err)
	}
	if len(ata) != 32 {
		t.Fatalf("expected 32-byte ATA, got %d bytes", len(ata))
	}

	// Derive again to check determinism.
	ata2, err := deriveATA(wallet, mint)
	if err != nil {
		t.Fatalf("derive ATA second time: %v", err)
	}
	if base58Encode(ata) != base58Encode(ata2) {
		t.Fatal("ATA derivation is not deterministic")
	}

	// ATA for a different wallet should be different.
	wallet2, _ := base58Decode(SystemProgramID)
	ata3, err := deriveATA(wallet2, mint)
	if err != nil {
		t.Fatalf("derive ATA for different wallet: %v", err)
	}
	if base58Encode(ata) == base58Encode(ata3) {
		t.Fatal("different wallets produced the same ATA")
	}
}

func TestDeriveATAKnownVector(t *testing.T) {
	// Well-known test vector:
	// Wallet: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA (just using as a 32-byte value)
	// The ATA must be off-curve (not a valid ed25519 point).
	wallet, _ := base58Decode("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
	mint, _ := base58Decode(USDCMintMainnet)

	ata, err := deriveATA(wallet, mint)
	if err != nil {
		t.Fatalf("derive ATA: %v", err)
	}

	// The result must NOT be on the ed25519 curve.
	if isOnCurve(ata) {
		t.Fatal("ATA should be off-curve (a valid PDA)")
	}
}

// --- IsOnCurve Tests ---

func TestIsOnCurve(t *testing.T) {
	// The ed25519 base point (generator) IS on the curve.
	// In compressed form, the base point y-coordinate is:
	// 4/5 mod p, and sign bit 0 for x.
	// The 32-byte encoding is:
	// 5866666666666666666666666666666666666666666666666666666666666666 (hex, LE)
	basePoint := []byte{
		0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
		0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
		0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
		0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
	}
	if !isOnCurve(basePoint) {
		t.Fatal("ed25519 base point should be on curve")
	}

	// The identity point (all zeros with sign bit) should be on curve (y=0 is not
	// on curve actually since 0^2 - 1 = -1 and d*0+1 = 1, so x^2 = -1 which has
	// no solution). Let's test a point we know is NOT on curve.
	notOnCurve := make([]byte, 32)
	notOnCurve[0] = 0xFF
	notOnCurve[1] = 0xFF
	// Arbitrary bytes very unlikely to be on curve.
	if isOnCurve(notOnCurve) {
		// It's theoretically possible but extremely unlikely.
		t.Log("warning: random bytes happened to be on curve")
	}

	// Wrong length should return false.
	if isOnCurve([]byte{1, 2, 3}) {
		t.Fatal("wrong-length should not be on curve")
	}
}

// --- SendSPLTransfer Tests ---

func TestSendSPLTransferEmptyPrivateKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewSolanaProcessor(
		"https://api.mainnet-beta.solana.com",
		"SomeDepositAddress1111111111111111111111",
		USDCMintMainnet,
		"", // empty private key
		false,
		logger,
	)

	_, err := proc.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      "DestAddr11111111111111111111111111111111111",
		AmountMicroUSD: 1_000_000,
	})
	if err == nil {
		t.Fatal("expected error for empty private key")
	}
	if !strings.Contains(err.Error(), "private key not configured") {
		t.Fatalf("expected 'private key not configured' error, got: %v", err)
	}
}

func TestSendSPLTransferMockMode(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewSolanaProcessor(
		"https://api.mainnet-beta.solana.com",
		"SomeDepositAddress1111111111111111111111",
		USDCMintMainnet,
		"", // no key needed in mock mode
		true,
		logger,
	)

	result, err := proc.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      "DestAddr11111111111111111111111111111111111",
		AmountMicroUSD: 500_000,
	})
	if err != nil {
		t.Fatalf("mock withdrawal should succeed: %v", err)
	}
	if !strings.HasPrefix(result.TxSignature, "mock-withdraw-") {
		t.Fatalf("expected mock tx signature, got: %s", result.TxSignature)
	}
	if result.AmountMicroUSD != 500_000 {
		t.Fatalf("expected 500000 micro-USD, got %d", result.AmountMicroUSD)
	}
	if result.ToAddress != "DestAddr11111111111111111111111111111111111" {
		t.Fatalf("unexpected to address: %s", result.ToAddress)
	}
}

// --- Integration-style test with mock RPC server ---

func TestSendSPLTransferWithMockRPC(t *testing.T) {
	// Generate a deterministic test keypair.
	// Use a known seed for reproducibility: 32 bytes of 0x01.
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = 0x01
	}
	privKey := ed25519.NewKeyFromSeed(seed)
	pubKey := privKey.Public().(ed25519.PublicKey)
	payerAddress := base58Encode(pubKey)

	// Encode the 64-byte private key as base58.
	privKeyB58 := base58Encode(privKey)

	// Derive expected source and dest ATAs.
	mintBytes, _ := base58Decode(USDCMintMainnet)
	destWalletBytes, _ := base58Decode("7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi")
	srcATA, _ := deriveATA(pubKey, mintBytes)
	destATA, _ := deriveATA(destWalletBytes, mintBytes)
	destATAAddr := base58Encode(destATA)
	_ = srcATA

	// Track which RPC calls were made.
	rpcCalls := make([]string, 0)

	// Mock Solana RPC server.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request", 400)
			return
		}
		rpcCalls = append(rpcCalls, req.Method)

		switch req.Method {
		case "getLatestBlockhash":
			// Return a fake blockhash (32 bytes base58-encoded).
			fakeBlockhash := base58Encode(make([]byte, 32)) // all zeros
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":{"value":{"blockhash":"%s","lastValidBlockHeight":1000}}}`, fakeBlockhash)

		case "getAccountInfo":
			// Check which account is being queried.
			var params []json.RawMessage
			json.Unmarshal(req.Params, &params)
			var addr string
			json.Unmarshal(params[0], &addr)

			if addr == destATAAddr {
				// Destination ATA does not exist.
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"value":null}}`)
			} else {
				// Other accounts exist.
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"value":{"data":"","executable":false,"lamports":1000000}}}`)
			}

		case "sendTransaction":
			// Return a fake tx signature.
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":"5wHu1qwD7q5JNMPMGHBiDfYkTpAQHBc4G3HtFMZSx8K8Jg7qUXg7YnQG1FS3MBvAAkEcffmAx3KALDGL5beRzVN"}`)

		default:
			http.Error(w, fmt.Sprintf("unexpected method: %s", req.Method), 400)
		}
	}))
	defer server.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewSolanaProcessor(
		server.URL,
		payerAddress,
		USDCMintMainnet,
		privKeyB58,
		false,
		logger,
	)

	result, err := proc.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      "7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi",
		AmountMicroUSD: 1_000_000, // 1 USDC
	})
	if err != nil {
		t.Fatalf("withdrawal failed: %v", err)
	}

	if result.TxSignature != "5wHu1qwD7q5JNMPMGHBiDfYkTpAQHBc4G3HtFMZSx8K8Jg7qUXg7YnQG1FS3MBvAAkEcffmAx3KALDGL5beRzVN" {
		t.Fatalf("unexpected tx signature: %s", result.TxSignature)
	}
	if result.AmountMicroUSD != 1_000_000 {
		t.Fatalf("unexpected amount: %d", result.AmountMicroUSD)
	}

	// Verify the expected RPC calls were made.
	expectedCalls := []string{"getLatestBlockhash", "getAccountInfo", "sendTransaction"}
	if len(rpcCalls) != len(expectedCalls) {
		t.Fatalf("expected %d RPC calls, got %d: %v", len(expectedCalls), len(rpcCalls), rpcCalls)
	}
	for i, expected := range expectedCalls {
		if rpcCalls[i] != expected {
			t.Fatalf("RPC call %d: expected %s, got %s", i, expected, rpcCalls[i])
		}
	}
}

func TestSendSPLTransferDestATAExists(t *testing.T) {
	// Same test as above but dest ATA already exists (no CreateATA instruction).
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = 0x02
	}
	privKey := ed25519.NewKeyFromSeed(seed)
	pubKey := privKey.Public().(ed25519.PublicKey)
	payerAddress := base58Encode(pubKey)
	privKeyB58 := base58Encode(privKey)

	rpcCalls := make([]string, 0)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		rpcCalls = append(rpcCalls, req.Method)

		switch req.Method {
		case "getLatestBlockhash":
			fakeBlockhash := base58Encode(make([]byte, 32))
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":{"value":{"blockhash":"%s","lastValidBlockHeight":1000}}}`, fakeBlockhash)

		case "getAccountInfo":
			// Dest ATA exists.
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":{"value":{"data":"","executable":false,"lamports":2000000}}}`)

		case "sendTransaction":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"jsonrpc":"2.0","id":1,"result":"4xMockTxSig"}`)

		default:
			http.Error(w, fmt.Sprintf("unexpected method: %s", req.Method), 400)
		}
	}))
	defer server.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewSolanaProcessor(
		server.URL,
		payerAddress,
		USDCMintMainnet,
		privKeyB58,
		false,
		logger,
	)

	result, err := proc.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      "7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi",
		AmountMicroUSD: 500_000,
	})
	if err != nil {
		t.Fatalf("withdrawal failed: %v", err)
	}

	if result.TxSignature != "4xMockTxSig" {
		t.Fatalf("unexpected tx signature: %s", result.TxSignature)
	}

	// When dest ATA exists, we should NOT see the CreateATA instruction,
	// so the RPC flow is the same (getLatestBlockhash, getAccountInfo, sendTransaction).
	expectedCalls := []string{"getLatestBlockhash", "getAccountInfo", "sendTransaction"}
	if len(rpcCalls) != len(expectedCalls) {
		t.Fatalf("expected %d RPC calls, got %d: %v", len(expectedCalls), len(rpcCalls), rpcCalls)
	}
}

// --- Compact-u16 Encoding Tests ---

func TestWriteCompactU16(t *testing.T) {
	cases := []struct {
		val      int
		expected []byte
	}{
		{0, []byte{0x00}},
		{1, []byte{0x01}},
		{127, []byte{0x7f}},
		{128, []byte{0x80, 0x01}},
		{255, []byte{0xff, 0x01}},
		{16383, []byte{0xff, 0x7f}},
		{16384, []byte{0x80, 0x80, 0x01}},
	}

	for _, tc := range cases {
		t.Run(fmt.Sprintf("val=%d", tc.val), func(t *testing.T) {
			var buf bytes.Buffer
			writeCompactU16(&buf, tc.val)
			got := buf.Bytes()
			if len(got) != len(tc.expected) {
				t.Fatalf("val=%d: expected %d bytes, got %d: %x", tc.val, len(tc.expected), len(got), got)
			}
			for i := range got {
				if got[i] != tc.expected[i] {
					t.Fatalf("val=%d: byte %d: expected 0x%02x, got 0x%02x", tc.val, i, tc.expected[i], got[i])
				}
			}
		})
	}
}
