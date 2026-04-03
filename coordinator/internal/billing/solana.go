package billing

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// SolanaProcessor handles deposit verification and withdrawals on Solana.
//
// Deposit flow:
//  1. Consumer sends USDC-SPL to the coordinator's Solana deposit address
//  2. Consumer submits tx signature to coordinator
//  3. We verify the tx via Solana JSON-RPC (getTransaction)
//  4. We parse the token transfer instructions to confirm amount and recipient
//  5. Credits consumer's internal balance
//
// Withdrawal flow:
//  1. Consumer requests withdrawal with destination address
//  2. Coordinator signs and sends SPL token transfer from hot wallet
//  3. Returns tx signature to consumer
type SolanaProcessor struct {
	rpcURL         string
	depositAddress string
	usdcMint       string
	privateKey     string // base58-encoded hot wallet key for withdrawals
	mockMode       bool
	logger         *slog.Logger
	httpClient     *http.Client
}

// NewSolanaProcessor creates a new Solana processor.
func NewSolanaProcessor(rpcURL, depositAddress, usdcMint, privateKey string, mockMode bool, logger *slog.Logger) *SolanaProcessor {
	return &SolanaProcessor{
		rpcURL:         rpcURL,
		depositAddress: depositAddress,
		usdcMint:       usdcMint,
		privateKey:     privateKey,
		mockMode:       mockMode,
		logger:         logger,
		httpClient:     &http.Client{Timeout: 30 * time.Second},
	}
}

// DepositAddress returns the Solana address consumers should send USDC to.
func (p *SolanaProcessor) DepositAddress() string {
	return p.depositAddress
}

// USDCMint returns the USDC-SPL mint address.
func (p *SolanaProcessor) USDCMint() string {
	return p.usdcMint
}

// SolanaDepositResult contains the verified Solana deposit details.
type SolanaDepositResult struct {
	TxSignature    string `json:"tx_signature"`
	From           string `json:"from"`
	To             string `json:"to"`
	AmountRaw      uint64 `json:"amount_raw"`       // raw token amount (USDC = 6 decimals)
	AmountMicroUSD int64  `json:"amount_micro_usd"` // 1:1 mapping for USDC (6 decimals)
	Slot           uint64 `json:"slot"`
	Confirmed      bool   `json:"confirmed"`
}

// VerifyDeposit verifies a Solana transaction contains a USDC-SPL transfer
// to the deposit address.
func (p *SolanaProcessor) VerifyDeposit(txSignature string) (*SolanaDepositResult, error) {
	// Fetch transaction details via Solana RPC
	tx, err := p.getTransaction(txSignature)
	if err != nil {
		return nil, fmt.Errorf("solana: get transaction: %w", err)
	}

	// Check transaction was successful
	meta, ok := tx["meta"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("solana: no meta in transaction")
	}

	if errField := meta["err"]; errField != nil {
		return nil, fmt.Errorf("solana: transaction failed: %v", errField)
	}

	slot, _ := tx["slot"].(float64)

	// Parse token balances to find USDC transfers to our deposit address
	preTokenBalances, _ := meta["preTokenBalances"].([]any)
	postTokenBalances, _ := meta["postTokenBalances"].([]any)

	// Build maps of account index → token balance for pre and post state
	type tokenBalance struct {
		Mint   string
		Owner  string
		Amount uint64
	}

	parseBalances := func(balances []any) map[int]tokenBalance {
		result := make(map[int]tokenBalance)
		for _, b := range balances {
			bMap, ok := b.(map[string]any)
			if !ok {
				continue
			}
			accountIndex := int(bMap["accountIndex"].(float64))
			mint, _ := bMap["mint"].(string)
			owner, _ := bMap["owner"].(string)
			uiAmountInfo, _ := bMap["uiTokenAmount"].(map[string]any)
			amountStr, _ := uiAmountInfo["amount"].(string)

			var amount uint64
			fmt.Sscanf(amountStr, "%d", &amount)

			result[accountIndex] = tokenBalance{
				Mint:   mint,
				Owner:  owner,
				Amount: amount,
			}
		}
		return result
	}

	preMap := parseBalances(preTokenBalances)
	postMap := parseBalances(postTokenBalances)

	depositAddr := p.depositAddress
	usdcMint := p.usdcMint

	// Find the deposit: look for our deposit address gaining USDC tokens
	for idx, postBal := range postMap {
		if strings.ToLower(postBal.Mint) != strings.ToLower(usdcMint) {
			continue
		}
		if postBal.Owner != depositAddr {
			continue
		}

		// Calculate the amount received
		preBal, hasPre := preMap[idx]
		var preAmount uint64
		if hasPre {
			preAmount = preBal.Amount
		}

		if postBal.Amount <= preAmount {
			continue // no increase
		}

		received := postBal.Amount - preAmount

		// Find the sender (account that lost USDC)
		var sender string
		for preIdx, pre := range preMap {
			if pre.Mint != usdcMint || pre.Owner == depositAddr {
				continue
			}
			postEntry, hasPost := postMap[preIdx]
			if hasPost && postEntry.Amount < pre.Amount {
				sender = pre.Owner
				break
			}
			if !hasPost {
				sender = pre.Owner
				break
			}
		}

		// USDC uses 6 decimals, same as micro-USD
		return &SolanaDepositResult{
			TxSignature:    txSignature,
			From:           sender,
			To:             depositAddr,
			AmountRaw:      received,
			AmountMicroUSD: int64(received),
			Slot:           uint64(slot),
			Confirmed:      true,
		}, nil
	}

	return nil, fmt.Errorf("solana: no matching USDC transfer to deposit address in tx %s", txSignature)
}

// rpcCall makes a JSON-RPC call to the Solana node.
func (p *SolanaProcessor) rpcCall(method string, params []any) (json.RawMessage, error) {
	reqBody := map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
		"id":      1,
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	resp, err := p.httpClient.Post(p.rpcURL, "application/json", bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("rpc request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read rpc response: %w", err)
	}

	var rpcResp struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(respBody, &rpcResp); err != nil {
		return nil, fmt.Errorf("parse rpc response: %w", err)
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	return rpcResp.Result, nil
}

// getTransaction fetches a confirmed transaction by signature.
func (p *SolanaProcessor) getTransaction(signature string) (map[string]any, error) {
	result, err := p.rpcCall("getTransaction", []any{
		signature,
		map[string]any{
			"encoding":                       "jsonParsed",
			"maxSupportedTransactionVersion": 0,
			"commitment":                     "confirmed",
		},
	})
	if err != nil {
		return nil, err
	}

	if string(result) == "null" {
		return nil, fmt.Errorf("transaction not found or not yet confirmed")
	}

	var tx map[string]any
	if err := json.Unmarshal(result, &tx); err != nil {
		return nil, fmt.Errorf("parse transaction: %w", err)
	}
	return tx, nil
}

// SolanaWithdrawRequest is the input for a Solana withdrawal.
type SolanaWithdrawRequest struct {
	ToAddress      string `json:"to_address"`
	AmountMicroUSD int64  `json:"amount_micro_usd"`
}

// SolanaWithdrawResult is the result of a Solana withdrawal.
type SolanaWithdrawResult struct {
	TxSignature    string `json:"tx_signature"`
	ToAddress      string `json:"to_address"`
	AmountMicroUSD int64  `json:"amount_micro_usd"`
}

// GetTokenBalance returns the USDC token balance for a wallet address.
// Returns the balance in raw token units (6 decimals for USDC = micro-USD).
func (p *SolanaProcessor) GetTokenBalance(walletAddress string) (uint64, error) {
	// Use getTokenAccountsByOwner to find the USDC token account.
	result, err := p.rpcCall("getTokenAccountsByOwner", []any{
		walletAddress,
		map[string]any{"mint": p.usdcMint},
		map[string]any{"encoding": "jsonParsed"},
	})
	if err != nil {
		return 0, fmt.Errorf("getTokenAccountsByOwner: %w", err)
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
		return 0, fmt.Errorf("parse token accounts: %w", err)
	}

	if len(resp.Value) == 0 {
		return 0, nil // no token account = zero balance
	}

	var balance uint64
	amountStr := resp.Value[0].Account.Data.Parsed.Info.TokenAmount.Amount
	fmt.Sscanf(amountStr, "%d", &balance)
	return balance, nil
}

// SendWithdrawal initiates a USDC-SPL transfer on Solana.
//
// In mock mode, returns a fake tx signature immediately (for dev/testing).
// In production mode, constructs and submits a real SPL token transfer
// using the hot wallet private key.
func (p *SolanaProcessor) SendWithdrawal(req SolanaWithdrawRequest) (*SolanaWithdrawResult, error) {
	if p.mockMode {
		p.logger.Info("solana: mock withdrawal",
			"to", req.ToAddress,
			"amount_micro_usd", req.AmountMicroUSD,
		)
		return &SolanaWithdrawResult{
			TxSignature:    fmt.Sprintf("mock-withdraw-%d-%s", time.Now().UnixNano(), req.ToAddress[:8]),
			ToAddress:      req.ToAddress,
			AmountMicroUSD: req.AmountMicroUSD,
		}, nil
	}

	if p.privateKey == "" {
		return nil, fmt.Errorf("solana: hot wallet private key not configured for withdrawals")
	}

	// Build the SPL token transfer instruction via Solana JSON-RPC.
	// This uses getLatestBlockhash + sendTransaction with the hot wallet key.
	return p.sendSPLTransfer(req)
}

// sendSPLTransfer constructs and submits a USDC-SPL token transfer on-chain.
func (p *SolanaProcessor) sendSPLTransfer(req SolanaWithdrawRequest) (*SolanaWithdrawResult, error) {
	// Step 1: Get a recent blockhash for the transaction.
	blockhashResult, err := p.rpcCall("getLatestBlockhash", []any{
		map[string]any{"commitment": "finalized"},
	})
	if err != nil {
		return nil, fmt.Errorf("solana: get blockhash: %w", err)
	}

	var bhResp struct {
		Value struct {
			Blockhash string `json:"blockhash"`
		} `json:"value"`
	}
	if err := json.Unmarshal(blockhashResult, &bhResp); err != nil {
		return nil, fmt.Errorf("solana: parse blockhash: %w", err)
	}

	// Step 2: Find the source token account (hot wallet's USDC ATA).
	srcResult, err := p.rpcCall("getTokenAccountsByOwner", []any{
		p.depositAddress,
		map[string]any{"mint": p.usdcMint},
		map[string]any{"encoding": "jsonParsed"},
	})
	if err != nil {
		return nil, fmt.Errorf("solana: find source token account: %w", err)
	}

	var srcAccounts struct {
		Value []struct {
			Pubkey string `json:"pubkey"`
		} `json:"value"`
	}
	if err := json.Unmarshal(srcResult, &srcAccounts); err != nil || len(srcAccounts.Value) == 0 {
		return nil, fmt.Errorf("solana: hot wallet has no USDC token account")
	}

	_ = srcAccounts.Value[0].Pubkey
	_ = bhResp.Value.Blockhash

	// Full SPL transfer requires constructing a raw transaction with:
	//   - CreateAssociatedTokenAccount (if dest ATA doesn't exist)
	//   - TokenInstruction::Transfer
	//   - Signing with hot wallet keypair
	// This needs a Solana SDK or raw transaction builder. For now, return
	// a clear error so we know exactly what's missing when we flip to prod.
	return nil, fmt.Errorf("solana: on-chain SPL transfer not yet wired — set DGINF_BILLING_MOCK=true for testing")
}
