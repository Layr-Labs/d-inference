package billing

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/pbkdf2"
)

// Solana program and mint constants.
const (
	// USDC-SPL mint on mainnet-beta.
	USDCMintMainnet = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

	// SPL Token Program ID.
	TokenProgramID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"

	// Associated Token Account Program ID.
	AssociatedTokenProgramID = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"

	// System Program ID.
	SystemProgramID = "11111111111111111111111111111111"
)

// solanaAlphabet is the base58 alphabet used by Solana (Bitcoin alphabet).
const solanaAlphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

// base58Decode decodes a base58-encoded string into bytes.
func base58Decode(s string) ([]byte, error) {
	if len(s) == 0 {
		return []byte{}, nil
	}

	// Build alphabet index.
	alphabetIdx := [256]int{}
	for i := range alphabetIdx {
		alphabetIdx[i] = -1
	}
	for i, c := range solanaAlphabet {
		alphabetIdx[c] = i
	}

	// Convert to big integer.
	result := new(big.Int)
	base := big.NewInt(58)
	for _, c := range s {
		idx := alphabetIdx[c]
		if idx < 0 {
			return nil, fmt.Errorf("base58: invalid character %q", c)
		}
		result.Mul(result, base)
		result.Add(result, big.NewInt(int64(idx)))
	}

	// Convert big.Int to bytes.
	decoded := result.Bytes()

	// Count leading '1's (zero bytes in base58).
	numLeadingZeros := 0
	for _, c := range s {
		if c != '1' {
			break
		}
		numLeadingZeros++
	}

	// Prepend zero bytes for leading '1's.
	if numLeadingZeros > 0 {
		decoded = append(make([]byte, numLeadingZeros), decoded...)
	}

	return decoded, nil
}

// base58Encode encodes bytes into a base58 string.
func base58Encode(data []byte) string {
	if len(data) == 0 {
		return ""
	}

	// Count leading zeros.
	numLeadingZeros := 0
	for _, b := range data {
		if b != 0 {
			break
		}
		numLeadingZeros++
	}

	// Convert to big integer.
	n := new(big.Int).SetBytes(data)
	base := big.NewInt(58)
	mod := new(big.Int)

	var encoded []byte
	zero := big.NewInt(0)
	for n.Cmp(zero) > 0 {
		n.DivMod(n, base, mod)
		encoded = append([]byte{solanaAlphabet[mod.Int64()]}, encoded...)
	}

	// Prepend '1' for each leading zero byte.
	for i := 0; i < numLeadingZeros; i++ {
		encoded = append([]byte{'1'}, encoded...)
	}

	return string(encoded)
}

// findProgramAddress derives a Program Derived Address (PDA).
// It iterates bump seeds from 255 down to 0 until finding an off-curve point.
func findProgramAddress(seeds [][]byte, programID []byte) ([]byte, uint8, error) {
	for bump := uint8(255); ; bump-- {
		h := sha256.New()
		for _, seed := range seeds {
			h.Write(seed)
		}
		h.Write([]byte{bump})
		h.Write(programID)
		h.Write([]byte("ProgramDerivedAddress"))
		candidate := h.Sum(nil)

		// A valid PDA must NOT be on the ed25519 curve.
		// If the 32-byte candidate is a valid ed25519 public key (i.e., a point
		// on the curve), it's not a valid PDA. We detect this by checking if
		// the point decompresses to a valid curve point.
		if !isOnCurve(candidate) {
			return candidate, bump, nil
		}

		if bump == 0 {
			break
		}
	}
	return nil, 0, fmt.Errorf("could not find valid PDA")
}

// isOnCurve checks if a 32-byte value is a valid ed25519 curve point.
// We use a trick: ed25519.Verify with a zero signature will fail, but the
// library first tries to decompress the point. If decompression fails, it
// panics or returns false. We use a simpler approach: try to do a
// ScalarBaseMult-style check by verifying the point is valid.
//
// Actually, Go's crypto/ed25519 does not expose point decompression directly.
// We use the edwards25519 low-level check: attempt to use the bytes as a
// curve point via the internal representation. Since Go 1.20, we can use
// the crypto/internal/edwards25519 package indirectly through
// filippo.io/edwards25519, but to avoid deps we use a practical approach:
//
// The ed25519 public key is a compressed Edwards point. We verify it by
// attempting ed25519.Verify with a known message/sig. If the public key is
// invalid (not on curve), Verify returns false without panicking.
func isOnCurve(pubkey []byte) bool {
	if len(pubkey) != 32 {
		return false
	}

	// Create a dummy ed25519 public key and attempt verification.
	// ed25519.Verify will decompress the point internally.
	// If the point is not on the curve, it returns false.
	// We sign a known message with a throwaway key to get a real signature format,
	// but actually we can just use a zero-filled signature -- Verify will still
	// attempt point decompression before checking the signature.
	//
	// NOTE: In Go's ed25519 implementation, Verify first checks if len(publicKey) == PublicKeySize,
	// then decompresses the point. If decompression fails, it returns false.
	// If decompression succeeds (point IS on curve), it returns false because
	// the signature is garbage. So both cases return false.
	//
	// Better approach: We use the low-level Edwards25519 point decompression.
	// Go 1.20+ has crypto/ed25519/internal/edwards25519 which is not importable.
	// Instead, we do the math ourselves for the y-coordinate check.
	//
	// For ed25519, a valid point must satisfy: x^2 = (y^2 - 1) / (d*y^2 + 1) mod p
	// where p = 2^255 - 19, d = -121665/121666 mod p.
	//
	// We check if the right-hand side is a quadratic residue (has a square root mod p).
	p := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))

	// Decode y from the 32-byte little-endian encoding.
	// The high bit of the last byte is the sign of x.
	yCopy := make([]byte, 32)
	copy(yCopy, pubkey)
	yCopy[31] &= 0x7f // Clear sign bit.

	// Convert from little-endian.
	y := new(big.Int)
	// Reverse bytes for big.Int (which expects big-endian).
	reversed := make([]byte, 32)
	for i := 0; i < 32; i++ {
		reversed[i] = yCopy[31-i]
	}
	y.SetBytes(reversed)

	// If y >= p, not a valid point.
	if y.Cmp(p) >= 0 {
		return false
	}

	// d = -121665 * inverse(121666) mod p
	d := new(big.Int).SetInt64(121666)
	d.ModInverse(d, p)
	d.Mul(d, big.NewInt(-121665))
	d.Mod(d, p)

	// Compute numerator: y^2 - 1
	y2 := new(big.Int).Mul(y, y)
	y2.Mod(y2, p)
	num := new(big.Int).Sub(y2, big.NewInt(1))
	num.Mod(num, p)

	// Compute denominator: d*y^2 + 1
	den := new(big.Int).Mul(d, y2)
	den.Add(den, big.NewInt(1))
	den.Mod(den, p)

	// x^2 = num * den^{-1} mod p
	denInv := new(big.Int).ModInverse(den, p)
	if denInv == nil {
		return false // denominator is 0 mod p, not on curve
	}
	x2 := new(big.Int).Mul(num, denInv)
	x2.Mod(x2, p)

	// Check if x2 is a quadratic residue: x2^((p-1)/2) == 1 mod p
	// (Euler's criterion). If x2 == 0, it's also valid (x = 0).
	if x2.Sign() == 0 {
		return true
	}
	exp := new(big.Int).Sub(p, big.NewInt(1))
	exp.Rsh(exp, 1)
	result := new(big.Int).Exp(x2, exp, p)
	return result.Cmp(big.NewInt(1)) == 0
}

// deriveATA derives the Associated Token Account address for a wallet and mint.
func deriveATA(wallet, mint []byte) ([]byte, error) {
	tokenProgram, err := base58Decode(TokenProgramID)
	if err != nil {
		return nil, fmt.Errorf("decode token program: %w", err)
	}
	atProgram, err := base58Decode(AssociatedTokenProgramID)
	if err != nil {
		return nil, fmt.Errorf("decode associated token program: %w", err)
	}

	seeds := [][]byte{wallet, tokenProgram, mint}
	addr, _, err := findProgramAddress(seeds, atProgram)
	if err != nil {
		return nil, fmt.Errorf("derive ATA: %w", err)
	}
	return addr, nil
}

// DeriveKeypairFromMnemonic derives a Solana ed25519 keypair from a BIP39 mnemonic.
//
// Uses SLIP-0010 (ed25519 key derivation) at path m/44'/501'/0'/0'.
// This matches Phantom, Solflare, and the Solana CLI's derivation.
//
// Returns the 64-byte ed25519 private key and the 32-byte public key (base58 address).
func DeriveKeypairFromMnemonic(mnemonic string) (ed25519.PrivateKey, string, error) {
	mnemonic = strings.TrimSpace(mnemonic)
	words := strings.Fields(mnemonic)
	if len(words) != 12 && len(words) != 24 {
		return nil, "", fmt.Errorf("mnemonic must be 12 or 24 words, got %d", len(words))
	}

	// BIP39: mnemonic → seed (PBKDF2 with "mnemonic" as salt, 2048 iterations)
	seed := pbkdf2.Key([]byte(mnemonic), []byte("mnemonic"), 2048, 64, sha512.New)

	// SLIP-0010: derive ed25519 key at m/44'/501'/0'/0'
	// Start with master key derivation
	key, chainCode := slip0010Master(seed)

	// Derive each segment of the path (all hardened)
	for _, index := range []uint32{44, 501, 0, 0} {
		key, chainCode = slip0010DeriveChild(key, chainCode, index+0x80000000)
	}

	// ed25519: seed (32 bytes) → 64-byte private key
	privKey := ed25519.NewKeyFromSeed(key)
	pubKey, ok := privKey.Public().(ed25519.PublicKey)
	if !ok {
		return nil, "", fmt.Errorf("ed25519 public key type assertion failed")
	}
	address := base58Encode(pubKey)

	return privKey, address, nil
}

// slip0010Master derives the master key and chain code from a BIP39 seed.
func slip0010Master(seed []byte) ([]byte, []byte) {
	mac := hmac.New(sha512.New, []byte("ed25519 seed"))
	mac.Write(seed)
	I := mac.Sum(nil)
	return I[:32], I[32:]
}

// slip0010DeriveChild derives a child key from a parent key and chain code.
func slip0010DeriveChild(key, chainCode []byte, index uint32) ([]byte, []byte) {
	buf := make([]byte, 37)
	buf[0] = 0x00
	copy(buf[1:33], key)
	binary.BigEndian.PutUint32(buf[33:], index)

	mac := hmac.New(sha512.New, chainCode)
	mac.Write(buf)
	I := mac.Sum(nil)
	return I[:32], I[32:]
}

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
	signingKey     string // base58-encoded 64-byte ed25519 key (derived from mnemonic)
	mockMode       bool
	logger         *slog.Logger
	httpClient     *http.Client
}

// NewSolanaProcessor creates a new Solana processor.
// signingKey is a base58-encoded ed25519 private key derived from the mnemonic.
func NewSolanaProcessor(rpcURL, depositAddress, usdcMint, signingKey string, mockMode bool, logger *slog.Logger) *SolanaProcessor {
	return &SolanaProcessor{
		rpcURL:         rpcURL,
		depositAddress: depositAddress,
		usdcMint:       usdcMint,
		signingKey:     signingKey,
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
//
//nolint:gocognit
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
			accountIndexF, _ := bMap["accountIndex"].(float64)
			accountIndex := int(accountIndexF)
			mint, _ := bMap["mint"].(string)
			owner, _ := bMap["owner"].(string)
			uiAmountInfo, _ := bMap["uiTokenAmount"].(map[string]any)
			amountStr, _ := uiAmountInfo["amount"].(string)

			var amount uint64
			_, _ = fmt.Sscanf(amountStr, "%d", &amount)

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
	_, _ = fmt.Sscanf(amountStr, "%d", &balance)
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

	if p.signingKey == "" {
		return nil, fmt.Errorf("solana: mnemonic not configured — withdrawals require MNEMONIC")
	}

	// Build the SPL token transfer instruction via Solana JSON-RPC.
	// This uses getLatestBlockhash + sendTransaction with the hot wallet key.
	return p.sendSPLTransfer(req)
}

// sendSPLTransfer constructs and submits a USDC-SPL token transfer on-chain.
func (p *SolanaProcessor) sendSPLTransfer(req SolanaWithdrawRequest) (*SolanaWithdrawResult, error) {
	if p.signingKey == "" {
		return nil, fmt.Errorf("solana signing key not configured")
	}

	// Step 1: Decode the hot wallet private key (base58 → 64 bytes).
	privKeyBytes, err := base58Decode(p.signingKey)
	if err != nil {
		return nil, fmt.Errorf("solana: decode private key: %w", err)
	}
	if len(privKeyBytes) != 64 {
		return nil, fmt.Errorf("solana: private key must be 64 bytes, got %d", len(privKeyBytes))
	}

	edPrivKey := ed25519.PrivateKey(privKeyBytes)
	payerPubkey, _ := edPrivKey.Public().(ed25519.PublicKey)

	// Step 2: Decode addresses.
	mintBytes, err := base58Decode(p.usdcMint)
	if err != nil {
		return nil, fmt.Errorf("solana: decode USDC mint: %w", err)
	}
	destWalletBytes, err := base58Decode(req.ToAddress)
	if err != nil {
		return nil, fmt.Errorf("solana: decode destination address: %w", err)
	}
	if len(destWalletBytes) != 32 {
		return nil, fmt.Errorf("solana: destination address must be 32 bytes, got %d", len(destWalletBytes))
	}

	// Step 3: Derive ATAs for source and destination.
	srcATA, err := deriveATA([]byte(payerPubkey), mintBytes)
	if err != nil {
		return nil, fmt.Errorf("solana: derive source ATA: %w", err)
	}
	destATA, err := deriveATA(destWalletBytes, mintBytes)
	if err != nil {
		return nil, fmt.Errorf("solana: derive destination ATA: %w", err)
	}

	// Step 4: Get latest blockhash.
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

	blockhashBytes, err := base58Decode(bhResp.Value.Blockhash)
	if err != nil {
		return nil, fmt.Errorf("solana: decode blockhash: %w", err)
	}

	// Step 5: Check if destination ATA exists.
	destATAExists, err := p.accountExists(base58Encode(destATA))
	if err != nil {
		return nil, fmt.Errorf("solana: check destination ATA: %w", err)
	}

	// Step 6: Build the transaction.
	tokenProgramBytes, err := base58Decode(TokenProgramID)
	if err != nil {
		return nil, fmt.Errorf("solana: decode token program: %w", err)
	}
	atProgramBytes, err := base58Decode(AssociatedTokenProgramID)
	if err != nil {
		return nil, fmt.Errorf("solana: decode associated token program: %w", err)
	}
	systemProgramBytes, err := base58Decode(SystemProgramID)
	if err != nil {
		return nil, fmt.Errorf("solana: decode system program: %w", err)
	}

	// Build instructions.
	var instructions []solanaInstruction

	if !destATAExists {
		// CreateAssociatedTokenAccount instruction.
		// Accounts: [payer(signer,writable), ata(writable), wallet, mint, systemProgram, tokenProgram]
		instructions = append(instructions, solanaInstruction{
			programID: atProgramBytes,
			accounts: []solanaAccountMeta{
				{pubkey: payerPubkey, isSigner: true, isWritable: true},
				{pubkey: destATA, isSigner: false, isWritable: true},
				{pubkey: destWalletBytes, isSigner: false, isWritable: false},
				{pubkey: mintBytes, isSigner: false, isWritable: false},
				{pubkey: systemProgramBytes, isSigner: false, isWritable: false},
				{pubkey: tokenProgramBytes, isSigner: false, isWritable: false},
			},
			data: []byte{}, // CreateAssociatedTokenAccount has no data
		})
	}

	// SPL Token Transfer instruction.
	// Instruction data: [3 (Transfer opcode)] + [uint64 LE amount]
	// USDC has 6 decimals; micro-USD maps 1:1 to raw USDC units.
	transferData := make([]byte, 9)
	transferData[0] = 3 // Transfer instruction discriminator
	binary.LittleEndian.PutUint64(transferData[1:], uint64(req.AmountMicroUSD))

	instructions = append(instructions, solanaInstruction{
		programID: tokenProgramBytes,
		accounts: []solanaAccountMeta{
			{pubkey: srcATA, isSigner: false, isWritable: true},
			{pubkey: destATA, isSigner: false, isWritable: true},
			{pubkey: payerPubkey, isSigner: true, isWritable: false}, // owner/authority
		},
		data: transferData,
	})

	// Step 7: Serialize the transaction message.
	txMsg := buildTransactionMessage(payerPubkey, instructions, blockhashBytes)

	// Step 8: Sign.
	signature := ed25519.Sign(edPrivKey, txMsg)

	// Step 9: Serialize the full transaction (signatures + message).
	var txBuf bytes.Buffer
	// Number of signatures (compact-u16).
	writeCompactU16(&txBuf, 1)
	txBuf.Write(signature)
	txBuf.Write(txMsg)

	// Step 10: Submit via sendTransaction RPC.
	txBase64 := base64.StdEncoding.EncodeToString(txBuf.Bytes())

	sendResult, err := p.rpcCall("sendTransaction", []any{
		txBase64,
		map[string]any{
			"encoding":            "base64",
			"skipPreflight":       false,
			"preflightCommitment": "confirmed",
		},
	})
	if err != nil {
		return nil, fmt.Errorf("solana: send transaction: %w", err)
	}

	var txSig string
	if err := json.Unmarshal(sendResult, &txSig); err != nil {
		return nil, fmt.Errorf("solana: parse tx signature: %w", err)
	}

	p.logger.Info("solana: SPL transfer sent",
		"tx_signature", txSig,
		"to", req.ToAddress,
		"amount_micro_usd", req.AmountMicroUSD,
		"created_ata", !destATAExists,
	)

	return &SolanaWithdrawResult{
		TxSignature:    txSig,
		ToAddress:      req.ToAddress,
		AmountMicroUSD: req.AmountMicroUSD,
	}, nil
}

// accountExists checks if a Solana account exists via getAccountInfo RPC.
func (p *SolanaProcessor) accountExists(address string) (bool, error) {
	result, err := p.rpcCall("getAccountInfo", []any{
		address,
		map[string]any{"encoding": "base64", "commitment": "confirmed"},
	})
	if err != nil {
		return false, err
	}

	var resp struct {
		Value *json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(result, &resp); err != nil {
		return false, fmt.Errorf("parse account info: %w", err)
	}

	return resp.Value != nil && string(*resp.Value) != "null", nil
}

// solanaAccountMeta describes an account in a Solana instruction.
type solanaAccountMeta struct {
	pubkey     []byte
	isSigner   bool
	isWritable bool
}

// solanaInstruction describes a single Solana instruction.
type solanaInstruction struct {
	programID []byte
	accounts  []solanaAccountMeta
	data      []byte
}

// buildTransactionMessage serializes a Solana v0-legacy transaction message.
// Format: header + account keys + recent blockhash + instructions.
//
//nolint:gocognit
func buildTransactionMessage(payer ed25519.PublicKey, instructions []solanaInstruction, recentBlockhash []byte) []byte {
	// Collect all unique account keys and classify them.
	type accountInfo struct {
		isSigner   bool
		isWritable bool
	}
	accountMap := make(map[string]accountInfo)
	accountOrder := make([]string, 0)

	addAccount := func(pubkey []byte, signer, writable bool) {
		key := string(pubkey)
		if existing, ok := accountMap[key]; ok {
			// Merge: promote to signer/writable if needed.
			accountMap[key] = accountInfo{
				isSigner:   existing.isSigner || signer,
				isWritable: existing.isWritable || writable,
			}
		} else {
			accountMap[key] = accountInfo{isSigner: signer, isWritable: writable}
			accountOrder = append(accountOrder, key)
		}
	}

	// Payer is always first, always signer + writable.
	addAccount([]byte(payer), true, true)

	// Add all accounts from instructions.
	for _, ix := range instructions {
		for _, acc := range ix.accounts {
			addAccount(acc.pubkey, acc.isSigner, acc.isWritable)
		}
		// Program IDs are read-only, non-signer.
		addAccount(ix.programID, false, false)
	}

	// Sort accounts into the four categories Solana expects:
	// 1. Writable signers
	// 2. Read-only signers
	// 3. Writable non-signers
	// 4. Read-only non-signers
	type categorizedAccount struct {
		key      string
		category int
	}
	var sorted []categorizedAccount
	for _, key := range accountOrder {
		info := accountMap[key]
		cat := 3 // read-only non-signer (default)
		if info.isSigner && info.isWritable {
			cat = 0
		} else if info.isSigner {
			cat = 1
		} else if info.isWritable {
			cat = 2
		}
		sorted = append(sorted, categorizedAccount{key: key, category: cat})
	}
	// Stable sort by category (preserving order within each category).
	for i := 1; i < len(sorted); i++ {
		for j := i; j > 0 && sorted[j].category < sorted[j-1].category; j-- {
			sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
		}
	}

	// Build the account keys list and index map.
	accountKeys := make([][]byte, len(sorted))
	keyIndex := make(map[string]int)
	numSigners := 0
	numReadonlySigned := 0
	numReadonlyUnsigned := 0

	for i, sa := range sorted {
		accountKeys[i] = []byte(sa.key)
		keyIndex[sa.key] = i
		info := accountMap[sa.key]
		if info.isSigner {
			numSigners++
			if !info.isWritable {
				numReadonlySigned++
			}
		} else if !info.isWritable {
			numReadonlyUnsigned++
		}
	}

	// Serialize the message.
	var msg bytes.Buffer

	// Header: numRequiredSignatures, numReadonlySignedAccounts, numReadonlyUnsignedAccounts
	msg.WriteByte(byte(numSigners))
	msg.WriteByte(byte(numReadonlySigned))
	msg.WriteByte(byte(numReadonlyUnsigned))

	// Account keys (compact-u16 length + 32-byte keys).
	writeCompactU16(&msg, len(accountKeys))
	for _, key := range accountKeys {
		msg.Write(key)
	}

	// Recent blockhash (32 bytes).
	msg.Write(recentBlockhash)

	// Instructions (compact-u16 count).
	writeCompactU16(&msg, len(instructions))
	for _, ix := range instructions {
		// Program ID index.
		msg.WriteByte(byte(keyIndex[string(ix.programID)]))

		// Account indices (compact-u16 length + indices).
		writeCompactU16(&msg, len(ix.accounts))
		for _, acc := range ix.accounts {
			msg.WriteByte(byte(keyIndex[string(acc.pubkey)]))
		}

		// Instruction data (compact-u16 length + data).
		writeCompactU16(&msg, len(ix.data))
		msg.Write(ix.data)
	}

	return msg.Bytes()
}

// writeCompactU16 writes a Solana compact-u16 encoding to the buffer.
// Values 0-127 use 1 byte, 128-16383 use 2 bytes, larger use 3 bytes.
func writeCompactU16(buf *bytes.Buffer, val int) {
	v := uint16(val)
	if v < 0x80 {
		buf.WriteByte(byte(v))
	} else if v < 0x4000 {
		buf.WriteByte(byte(v&0x7f) | 0x80)
		buf.WriteByte(byte(v >> 7))
	} else {
		buf.WriteByte(byte(v&0x7f) | 0x80)
		buf.WriteByte(byte((v>>7)&0x7f) | 0x80)
		buf.WriteByte(byte(v >> 14))
	}
}
