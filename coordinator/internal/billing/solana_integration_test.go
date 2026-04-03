package billing

// Integration test for Solana SPL transfers against a local solana-test-validator.
//
// Prerequisites (run manually before this test):
//   1. solana-test-validator --reset --quiet &
//   2. Create keypairs, airdrop SOL, create token mint, mint tokens
//
// This test is skipped unless SOLANA_INTEGRATION_TEST=1 is set.
// It verifies actual on-chain token transfers, ATA creation, and balance changes.

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"
)

func TestSolanaIntegration_RealTransfer(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping real Solana test (requires local validator)")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	privateKey := os.Getenv("SOLANA_HOT_WALLET_KEY")
	if privateKey == "" {
		t.Fatal("SOLANA_HOT_WALLET_KEY must be set (base58 private key)")
	}
	destAddress := os.Getenv("SOLANA_DEST_ADDRESS")
	if destAddress == "" {
		t.Fatal("SOLANA_DEST_ADDRESS must be set")
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, "", usdcMint, privateKey, false, logger)

	// Decode hot wallet public key for balance checks.
	privBytes, err := base58Decode(privateKey)
	if err != nil {
		t.Fatalf("decode private key: %v", err)
	}
	hotWalletAddress := base58Encode(privBytes[32:])
	t.Logf("Hot wallet: %s", hotWalletAddress)
	t.Logf("Destination: %s", destAddress)
	t.Logf("USDC mint: %s", usdcMint)

	// Step 1: Check hot wallet has tokens.
	srcBalance := getTokenBalance(t, sp, hotWalletAddress)
	t.Logf("Hot wallet balance before: %d micro-USDC", srcBalance)
	if srcBalance < 5_000_000 {
		t.Fatalf("hot wallet needs at least 5 USDC, has %d micro-USDC", srcBalance)
	}

	// Step 2: Check dest balance before transfer.
	destBalanceBefore := getTokenBalance(t, sp, destAddress)
	t.Logf("Dest balance before: %d micro-USDC", destBalanceBefore)

	// Step 3: Send 2.5 USDC (2,500,000 micro-USD).
	amount := int64(2_500_000)
	t.Logf("Sending %d micro-USDC...", amount)

	result, err := sp.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      destAddress,
		AmountMicroUSD: amount,
	})
	if err != nil {
		t.Fatalf("SendWithdrawal failed: %v", err)
	}

	t.Logf("Transaction signature: %s", result.TxSignature)

	if result.TxSignature == "" {
		t.Fatal("empty tx signature")
	}
	if result.ToAddress != destAddress {
		t.Errorf("to_address = %q, want %q", result.ToAddress, destAddress)
	}
	if result.AmountMicroUSD != amount {
		t.Errorf("amount = %d, want %d", result.AmountMicroUSD, amount)
	}

	// Step 4: Wait for confirmation and verify balances changed.
	time.Sleep(2 * time.Second)

	srcBalanceAfter := getTokenBalance(t, sp, hotWalletAddress)
	destBalanceAfter := getTokenBalance(t, sp, destAddress)

	t.Logf("Hot wallet balance after: %d micro-USDC (was %d)", srcBalanceAfter, srcBalance)
	t.Logf("Dest balance after: %d micro-USDC (was %d)", destBalanceAfter, destBalanceBefore)

	// Verify source decreased by the transfer amount.
	expectedSrcBalance := srcBalance - amount
	if srcBalanceAfter != expectedSrcBalance {
		t.Errorf("source balance = %d, want %d (decreased by %d)", srcBalanceAfter, expectedSrcBalance, amount)
	}

	// Verify destination increased by the transfer amount.
	expectedDestBalance := destBalanceBefore + amount
	if destBalanceAfter != expectedDestBalance {
		t.Errorf("dest balance = %d, want %d (increased by %d)", destBalanceAfter, expectedDestBalance, amount)
	}

	t.Logf("SUCCESS: %d micro-USDC transferred on-chain", amount)
}

func TestSolanaIntegration_ATACreation(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	privateKey := os.Getenv("SOLANA_HOT_WALLET_KEY")
	if privateKey == "" {
		t.Fatal("SOLANA_HOT_WALLET_KEY required")
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT required")
	}
	// Use a fresh wallet that definitely has no ATA.
	freshAddress := os.Getenv("SOLANA_FRESH_ADDRESS")
	if freshAddress == "" {
		t.Skip("SOLANA_FRESH_ADDRESS not set — skipping ATA creation test")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, "", usdcMint, privateKey, false, logger)

	// Verify ATA doesn't exist yet.
	mintBytes, _ := base58Decode(usdcMint)
	freshBytes, _ := base58Decode(freshAddress)
	ata, _ := deriveATA(freshBytes, mintBytes)
	ataAddr := base58Encode(ata)

	exists, err := sp.accountExists(ataAddr)
	if err != nil {
		t.Fatalf("check ATA: %v", err)
	}
	if exists {
		t.Skip("ATA already exists — can't test creation")
	}

	t.Logf("Fresh wallet %s has no ATA — testing creation", freshAddress)

	// Send small amount — should create ATA + transfer.
	result, err := sp.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      freshAddress,
		AmountMicroUSD: 100_000, // 0.10 USDC
	})
	if err != nil {
		t.Fatalf("SendWithdrawal (with ATA creation): %v", err)
	}

	t.Logf("TX: %s", result.TxSignature)

	time.Sleep(3 * time.Second)

	// Verify ATA was created.
	exists, err = sp.accountExists(ataAddr)
	if err != nil {
		t.Fatalf("check ATA after: %v", err)
	}
	if !exists {
		t.Fatal("ATA should exist after transfer with creation")
	}

	// Verify balance.
	balance := getTokenBalance(t, sp, freshAddress)
	if balance != 100_000 {
		t.Errorf("fresh wallet balance = %d, want 100000", balance)
	}

	t.Logf("SUCCESS: ATA created and %d micro-USDC received", balance)
}

func TestSolanaIntegration_SecondTransfer(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	privateKey := os.Getenv("SOLANA_HOT_WALLET_KEY")
	if privateKey == "" {
		t.Fatal("SOLANA_HOT_WALLET_KEY required")
	}
	destAddress := os.Getenv("SOLANA_DEST_ADDRESS")
	if destAddress == "" {
		t.Fatal("SOLANA_DEST_ADDRESS required")
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT required")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, "", usdcMint, privateKey, false, logger)

	before := getTokenBalance(t, sp, destAddress)

	// Send another transfer — ATA already exists this time.
	result, err := sp.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      destAddress,
		AmountMicroUSD: 1_000_000, // 1 USDC
	})
	if err != nil {
		t.Fatalf("second transfer failed: %v", err)
	}

	t.Logf("TX: %s", result.TxSignature)
	time.Sleep(2 * time.Second)

	after := getTokenBalance(t, sp, destAddress)
	if after != before+1_000_000 {
		t.Errorf("balance = %d, want %d", after, before+1_000_000)
	}
	t.Logf("SUCCESS: second transfer (ATA existed) — balance %d → %d", before, after)
}

// getTokenBalance returns the token balance for a wallet using getTokenAccountsByOwner.
func getTokenBalance(t *testing.T, sp *SolanaProcessor, walletAddress string) int64 {
	t.Helper()

	result, err := sp.rpcCall("getTokenAccountsByOwner", []any{
		walletAddress,
		map[string]any{"mint": sp.usdcMint},
		map[string]any{"encoding": "jsonParsed", "commitment": "confirmed"},
	})
	if err != nil {
		// No token accounts = 0 balance.
		return 0
	}

	var resp struct {
		Value []struct {
			Account struct {
				Data struct {
					Parsed struct {
						Info struct {
							TokenAmount struct {
								Amount string `json:"amount"`
							} `json:"tokenAmount"`
						} `json:"info"`
					} `json:"parsed"`
				} `json:"data"`
			} `json:"account"`
		} `json:"value"`
	}

	if err := json.Unmarshal(result, &resp); err != nil {
		return 0
	}
	if len(resp.Value) == 0 {
		return 0
	}

	var balance int64
	fmt.Sscanf(resp.Value[0].Account.Data.Parsed.Info.TokenAmount.Amount, "%d", &balance)
	return balance
}
