package billing

// Integration tests for Solana deposit verification and full payment lifecycle.
//
// Prerequisites:
//   1. solana-test-validator running at http://127.0.0.1:8899
//   2. source /tmp/solana-test-env.sh (sets SOLANA_INTEGRATION_TEST=1 and wallet/mint env vars)
//   3. A pre-existing deposit TX from consumer → hot wallet (25 USDC)
//
// Skipped unless SOLANA_INTEGRATION_TEST=1.

import (
	"log/slog"
	"os"
	"testing"
	"time"
)

func TestSolanaIntegration_DepositVerification(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}
	hotWalletAddress := os.Getenv("SOLANA_HOT_WALLET_ADDRESS")
	if hotWalletAddress == "" {
		t.Fatal("SOLANA_HOT_WALLET_ADDRESS must be set")
	}
	depositTx := os.Getenv("SOLANA_DEPOSIT_TX")
	if depositTx == "" {
		t.Fatal("SOLANA_DEPOSIT_TX must be set")
	}
	consumerAddress := os.Getenv("SOLANA_CONSUMER_ADDRESS")
	if consumerAddress == "" {
		t.Fatal("SOLANA_CONSUMER_ADDRESS must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, hotWalletAddress, usdcMint, "", false, logger)

	result, err := sp.VerifyDeposit(depositTx)
	if err != nil {
		t.Fatalf("VerifyDeposit failed: %v", err)
	}

	if result.From != consumerAddress {
		t.Errorf("From = %q, want %q", result.From, consumerAddress)
	}
	if result.AmountMicroUSD != 25_000_000 {
		t.Errorf("AmountMicroUSD = %d, want 25000000 (25 USDC)", result.AmountMicroUSD)
	}
	if result.TxSignature != depositTx {
		t.Errorf("TxSignature = %q, want %q", result.TxSignature, depositTx)
	}
	if !result.Confirmed {
		t.Error("expected Confirmed = true")
	}

	t.Logf("Deposit verified: %d micro-USDC from %s (slot %d)", result.AmountMicroUSD, result.From, result.Slot)
}

func TestSolanaIntegration_DepositDoubleSpend(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}
	hotWalletAddress := os.Getenv("SOLANA_HOT_WALLET_ADDRESS")
	if hotWalletAddress == "" {
		t.Fatal("SOLANA_HOT_WALLET_ADDRESS must be set")
	}
	depositTx := os.Getenv("SOLANA_DEPOSIT_TX")
	if depositTx == "" {
		t.Fatal("SOLANA_DEPOSIT_TX must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, hotWalletAddress, usdcMint, "", false, logger)

	// First verification.
	result1, err := sp.VerifyDeposit(depositTx)
	if err != nil {
		t.Fatalf("first VerifyDeposit failed: %v", err)
	}

	// Second verification of the same TX — the processor itself does not track
	// processed external IDs (that is the store's responsibility), so both calls
	// should return the same valid result.
	result2, err := sp.VerifyDeposit(depositTx)
	if err != nil {
		t.Fatalf("second VerifyDeposit failed: %v", err)
	}

	// Both results must be identical.
	if result1.TxSignature != result2.TxSignature {
		t.Errorf("TxSignature mismatch: %q vs %q", result1.TxSignature, result2.TxSignature)
	}
	if result1.From != result2.From {
		t.Errorf("From mismatch: %q vs %q", result1.From, result2.From)
	}
	if result1.AmountMicroUSD != result2.AmountMicroUSD {
		t.Errorf("AmountMicroUSD mismatch: %d vs %d", result1.AmountMicroUSD, result2.AmountMicroUSD)
	}
	if result1.Slot != result2.Slot {
		t.Errorf("Slot mismatch: %d vs %d", result1.Slot, result2.Slot)
	}

	t.Logf("Double-spend check: both calls returned identical results (amount=%d, from=%s)", result1.AmountMicroUSD, result1.From)
}

func TestSolanaIntegration_DepositWrongRecipient(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}
	depositTx := os.Getenv("SOLANA_DEPOSIT_TX")
	if depositTx == "" {
		t.Fatal("SOLANA_DEPOSIT_TX must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))

	// Use the consumer address as the "deposit address" — this is NOT where the
	// tokens were sent, so VerifyDeposit should fail to find a matching transfer.
	wrongAddress := os.Getenv("SOLANA_CONSUMER_ADDRESS")
	if wrongAddress == "" {
		wrongAddress = "11111111111111111111111111111111" // fallback: system program (definitely not the recipient)
	}

	sp := NewSolanaProcessor(rpcURL, wrongAddress, usdcMint, "", false, logger)

	result, err := sp.VerifyDeposit(depositTx)
	if err == nil && result != nil && result.AmountMicroUSD > 0 {
		t.Fatalf("expected error or zero amount for wrong recipient, got amount=%d to=%s", result.AmountMicroUSD, result.To)
	}

	t.Logf("Wrong recipient correctly rejected: err=%v", err)
}

func TestSolanaIntegration_DepositInvalidTx(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}
	hotWalletAddress := os.Getenv("SOLANA_HOT_WALLET_ADDRESS")
	if hotWalletAddress == "" {
		t.Fatal("SOLANA_HOT_WALLET_ADDRESS must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, hotWalletAddress, usdcMint, "", false, logger)

	bogusSignature := "1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"

	_, err := sp.VerifyDeposit(bogusSignature)
	if err == nil {
		t.Fatal("expected error for invalid/nonexistent tx signature")
	}

	t.Logf("Invalid TX correctly rejected: %v", err)
}

func TestSolanaIntegration_FullPaymentLifecycle(t *testing.T) {
	if os.Getenv("SOLANA_INTEGRATION_TEST") != "1" {
		t.Skip("SOLANA_INTEGRATION_TEST=1 not set — skipping")
	}

	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		rpcURL = "http://127.0.0.1:8899"
	}
	privateKey := os.Getenv("SOLANA_HOT_WALLET_KEY")
	if privateKey == "" {
		t.Fatal("SOLANA_HOT_WALLET_KEY must be set")
	}
	usdcMint := os.Getenv("SOLANA_USDC_MINT")
	if usdcMint == "" {
		t.Fatal("SOLANA_USDC_MINT must be set")
	}
	hotWalletAddress := os.Getenv("SOLANA_HOT_WALLET_ADDRESS")
	if hotWalletAddress == "" {
		t.Fatal("SOLANA_HOT_WALLET_ADDRESS must be set")
	}
	depositTx := os.Getenv("SOLANA_DEPOSIT_TX")
	if depositTx == "" {
		t.Fatal("SOLANA_DEPOSIT_TX must be set")
	}
	consumerAddress := os.Getenv("SOLANA_CONSUMER_ADDRESS")
	if consumerAddress == "" {
		t.Fatal("SOLANA_CONSUMER_ADDRESS must be set")
	}
	destAddress := os.Getenv("SOLANA_DEST_ADDRESS")
	if destAddress == "" {
		t.Fatal("SOLANA_DEST_ADDRESS must be set")
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	sp := NewSolanaProcessor(rpcURL, hotWalletAddress, usdcMint, privateKey, false, logger)

	// --- Phase 1: Record hot wallet balance before ---
	hotBalanceBefore := getTokenBalance(t, sp, hotWalletAddress)
	t.Logf("[lifecycle] hot wallet balance before: %d micro-USDC", hotBalanceBefore)

	destBalanceBefore := getTokenBalance(t, sp, destAddress)
	t.Logf("[lifecycle] dest wallet balance before: %d micro-USDC", destBalanceBefore)

	// --- Phase 2: Verify the existing deposit TX ---
	t.Log("[lifecycle] verifying deposit TX...")
	deposit, err := sp.VerifyDeposit(depositTx)
	if err != nil {
		t.Fatalf("VerifyDeposit failed: %v", err)
	}
	if deposit.From != consumerAddress {
		t.Errorf("deposit From = %q, want %q", deposit.From, consumerAddress)
	}
	if deposit.AmountMicroUSD != 25_000_000 {
		t.Errorf("deposit amount = %d, want 25000000", deposit.AmountMicroUSD)
	}
	t.Logf("[lifecycle] deposit verified: %d micro-USDC from %s", deposit.AmountMicroUSD, deposit.From)

	// --- Phase 3: Simulate internal accounting ---
	consumerBalance := deposit.AmountMicroUSD // credit 25 USDC
	t.Logf("[lifecycle] consumer credited: %d micro-USDC", consumerBalance)

	// --- Phase 4: Send withdrawal of 10 USDC to dest ---
	withdrawAmount := int64(10_000_000) // 10 USDC
	if consumerBalance < withdrawAmount {
		t.Fatalf("insufficient consumer balance: %d < %d", consumerBalance, withdrawAmount)
	}

	t.Logf("[lifecycle] sending withdrawal of %d micro-USDC to %s...", withdrawAmount, destAddress)
	withdrawResult, err := sp.SendWithdrawal(SolanaWithdrawRequest{
		ToAddress:      destAddress,
		AmountMicroUSD: withdrawAmount,
	})
	if err != nil {
		t.Fatalf("SendWithdrawal failed: %v", err)
	}
	consumerBalance -= withdrawAmount
	t.Logf("[lifecycle] withdrawal TX: %s", withdrawResult.TxSignature)
	t.Logf("[lifecycle] consumer balance remaining: %d micro-USDC", consumerBalance)

	if withdrawResult.TxSignature == "" {
		t.Fatal("empty withdrawal tx signature")
	}
	if withdrawResult.ToAddress != destAddress {
		t.Errorf("withdrawal to = %q, want %q", withdrawResult.ToAddress, destAddress)
	}
	if withdrawResult.AmountMicroUSD != withdrawAmount {
		t.Errorf("withdrawal amount = %d, want %d", withdrawResult.AmountMicroUSD, withdrawAmount)
	}

	// --- Phase 5: Wait for confirmation, verify balances changed ---
	time.Sleep(2 * time.Second)

	hotBalanceAfter := getTokenBalance(t, sp, hotWalletAddress)
	destBalanceAfter := getTokenBalance(t, sp, destAddress)

	t.Logf("[lifecycle] hot wallet balance after: %d micro-USDC (was %d)", hotBalanceAfter, hotBalanceBefore)
	t.Logf("[lifecycle] dest wallet balance after: %d micro-USDC (was %d)", destBalanceAfter, destBalanceBefore)

	// --- Phase 6: Verify hot wallet decreased ---
	expectedHotBalance := hotBalanceBefore - withdrawAmount
	if hotBalanceAfter != expectedHotBalance {
		t.Errorf("hot wallet balance = %d, want %d (decreased by %d)", hotBalanceAfter, expectedHotBalance, withdrawAmount)
	}

	// --- Phase 7: Verify dest wallet increased ---
	expectedDestBalance := destBalanceBefore + withdrawAmount
	if destBalanceAfter != expectedDestBalance {
		t.Errorf("dest balance = %d, want %d (increased by %d)", destBalanceAfter, expectedDestBalance, withdrawAmount)
	}

	t.Logf("[lifecycle] FULL LIFECYCLE COMPLETE:")
	t.Logf("  deposit:    %d micro-USDC verified from %s", deposit.AmountMicroUSD, deposit.From)
	t.Logf("  withdrawal: %d micro-USDC sent to %s (tx: %s)", withdrawAmount, destAddress, withdrawResult.TxSignature)
	t.Logf("  remaining:  %d micro-USDC consumer balance", consumerBalance)
}
