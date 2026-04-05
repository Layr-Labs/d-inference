// Package auth provides Privy-based authentication for the EigenInference coordinator.
//
// Privy issues ES256 (ECDSA P-256) JWTs to authenticated users. The coordinator
// verifies these tokens using the app's verification key from the Privy dashboard.
// On first authentication, the coordinator auto-creates a user record by fetching
// wallet details from the Privy REST API.
package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// PrivyAuth handles JWT verification and user provisioning via Privy.
type PrivyAuth struct {
	appID           string
	appSecret       string
	verificationKey *ecdsa.PublicKey
	store           store.Store
	logger          *slog.Logger
	httpClient      *http.Client
}

// Config holds Privy authentication configuration.
type Config struct {
	AppID           string // Privy app ID (also used as JWT audience)
	AppSecret       string // Privy app secret (for REST API basic auth)
	VerificationKey string // PEM-encoded ES256 public key from Privy dashboard
}

// NewPrivyAuth creates a new Privy authenticator.
func NewPrivyAuth(cfg Config, st store.Store, logger *slog.Logger) (*PrivyAuth, error) {
	if cfg.AppID == "" || cfg.VerificationKey == "" {
		return nil, fmt.Errorf("privy: app_id and verification_key are required")
	}

	// Parse the PEM-encoded ES256 verification key.
	// Replace literal \n with actual newlines (env vars can't contain newlines).
	keyPEM := strings.ReplaceAll(cfg.VerificationKey, `\n`, "\n")
	block, _ := pem.Decode([]byte(keyPEM))
	if block == nil {
		return nil, fmt.Errorf("privy: failed to decode verification key PEM")
	}

	pubKey, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("privy: parse verification key: %w", err)
	}

	ecKey, ok := pubKey.(*ecdsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("privy: verification key is not an ECDSA key")
	}

	return &PrivyAuth{
		appID:           cfg.AppID,
		appSecret:       cfg.AppSecret,
		verificationKey: ecKey,
		store:           st,
		logger:          logger,
		httpClient:      &http.Client{Timeout: 10 * time.Second},
	}, nil
}

// PrivyClaims represents the JWT claims from a Privy access token.
type PrivyClaims struct {
	jwt.RegisteredClaims
	SessionID string `json:"sid,omitempty"`
}

// VerifyToken verifies a Privy access token and returns the user's Privy DID.
func (p *PrivyAuth) VerifyToken(tokenStr string) (string, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &PrivyClaims{}, func(token *jwt.Token) (interface{}, error) {
		if token.Method.Alg() != "ES256" {
			return nil, fmt.Errorf("privy: unexpected signing method %v", token.Header["alg"])
		}
		return p.verificationKey, nil
	},
		jwt.WithIssuer("privy.io"),
		jwt.WithAudience(p.appID),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return "", fmt.Errorf("privy: token verification failed: %w", err)
	}

	claims, ok := token.Claims.(*PrivyClaims)
	if !ok || claims.Subject == "" {
		return "", fmt.Errorf("privy: invalid token claims")
	}

	return claims.Subject, nil // subject is the Privy DID (e.g. "did:privy:abc123")
}

// GetOrCreateUser looks up an existing user by Privy DID, or creates one by
// fetching wallet details from Privy's REST API.
func (p *PrivyAuth) GetOrCreateUser(privyUserID string) (*store.User, error) {
	// Try existing user first.
	user, err := p.store.GetUserByPrivyID(privyUserID)
	if err == nil {
		return user, nil
	}

	// Fetch user details from Privy to get wallet and email info.
	details, err := p.fetchUserDetails(privyUserID)
	if err != nil {
		p.logger.Error("privy: failed to fetch user details", "privy_user_id", privyUserID, "error", err)
		details = &privyUserDetails{}
	}

	user = &store.User{
		AccountID:           uuid.New().String(),
		PrivyUserID:         privyUserID,
		Email:               details.Email,
		SolanaWalletAddress: details.WalletAddress,
		SolanaWalletID:      details.WalletID,
	}

	if err := p.store.CreateUser(user); err != nil {
		// Race condition: another request created the user first.
		if existing, err2 := p.store.GetUserByPrivyID(privyUserID); err2 == nil {
			return existing, nil
		}
		return nil, fmt.Errorf("privy: create user: %w", err)
	}

	p.logger.Info("privy: created user",
		"privy_user_id", privyUserID,
		"account_id", user.AccountID,
		"email", details.Email,
		"has_wallet", details.WalletAddress != "",
	)

	return user, nil
}

// privyUserResponse represents the relevant fields from GET /api/v1/users/{id}.
type privyUserResponse struct {
	ID             string          `json:"id"`
	LinkedAccounts []linkedAccount `json:"linked_accounts"`
}

type linkedAccount struct {
	Type      string `json:"type"`
	Address   string `json:"address,omitempty"`
	ChainType string `json:"chain_type,omitempty"`
	WalletID  string `json:"wallet_client_type,omitempty"`
	// For embedded wallets, the ID is in a nested field.
	ID string `json:"id,omitempty"`
}

// privyUserDetails holds extracted info from the Privy user API.
type privyUserDetails struct {
	Email         string
	WalletAddress string
	WalletID      string
}

// fetchUserDetails calls Privy's REST API to get the user's email and wallet.
func (p *PrivyAuth) fetchUserDetails(privyUserID string) (*privyUserDetails, error) {
	if p.appSecret == "" {
		return nil, fmt.Errorf("privy: app_secret required for REST API calls")
	}

	req, err := http.NewRequestWithContext(context.Background(), "GET",
		"https://auth.privy.io/api/v1/users/"+privyUserID, nil)
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(p.appID, p.appSecret)
	req.Header.Set("privy-app-id", p.appID)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("privy: API request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("privy: API returned %d: %s", resp.StatusCode, string(body))
	}

	var userResp privyUserResponse
	if err := json.NewDecoder(resp.Body).Decode(&userResp); err != nil {
		return nil, fmt.Errorf("privy: decode user response: %w", err)
	}

	details := &privyUserDetails{}

	for _, acct := range userResp.LinkedAccounts {
		switch acct.Type {
		case "email":
			details.Email = acct.Address
		case "wallet":
			if acct.ChainType == "solana" {
				details.WalletAddress = acct.Address
				details.WalletID = acct.ID
			}
		}
	}

	return details, nil
}

// InitEmailOTP sends an OTP code to the given email address via Privy's API.
// This is used by the admin CLI to authenticate without a browser.
func (p *PrivyAuth) InitEmailOTP(email string) error {
	if p.appSecret == "" {
		return fmt.Errorf("privy: app_secret required for OTP init")
	}

	body := fmt.Sprintf(`{"email":"%s"}`, email)
	req, err := http.NewRequestWithContext(context.Background(), "POST",
		"https://auth.privy.io/api/v1/auth/email/init", strings.NewReader(body))
	if err != nil {
		return err
	}
	req.SetBasicAuth(p.appID, p.appSecret)
	req.Header.Set("privy-app-id", p.appID)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("privy: OTP init request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("privy: OTP init returned %d: %s", resp.StatusCode, string(respBody))
	}

	return nil
}

// VerifyEmailOTP verifies the OTP code and returns a Privy access token.
func (p *PrivyAuth) VerifyEmailOTP(email, code string) (string, error) {
	if p.appSecret == "" {
		return "", fmt.Errorf("privy: app_secret required for OTP verify")
	}

	body := fmt.Sprintf(`{"email":"%s","code":"%s"}`, email, code)
	req, err := http.NewRequestWithContext(context.Background(), "POST",
		"https://auth.privy.io/api/v1/auth/email/authenticate", strings.NewReader(body))
	if err != nil {
		return "", err
	}
	req.SetBasicAuth(p.appID, p.appSecret)
	req.Header.Set("privy-app-id", p.appID)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("privy: OTP verify request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return "", fmt.Errorf("privy: OTP verify returned %d: %s", resp.StatusCode, string(respBody))
	}

	var result struct {
		Token string `json:"token"`
		User  struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("privy: decode OTP response: %w", err)
	}

	if result.Token == "" {
		return "", fmt.Errorf("privy: no token in OTP response")
	}

	return result.Token, nil
}

// ContextKey for storing user in request context.
type ContextKey int

// CtxKeyUser is the context key for the authenticated User.
const CtxKeyUser ContextKey = iota

// UserFromContext retrieves the authenticated User from the request context.
func UserFromContext(ctx context.Context) *store.User {
	if u, ok := ctx.Value(CtxKeyUser).(*store.User); ok {
		return u
	}
	return nil
}
