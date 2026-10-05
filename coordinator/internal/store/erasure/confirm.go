package erasure

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
	"time"
)

const (
	// GlobalPayoutReconcileWindow is how long a posted Global Payout can still
	// be returned; ListGlobalPayoutsToReconcile reads it during this window.
	GlobalPayoutReconcileWindow = 90 * 24 * time.Hour
	// StripePayoutBounceWindow is how long a paid Stripe withdrawal still
	// counts as open. A bank can return a payout after Stripe marked it paid
	// (payout.failed after payout.paid), which refunds the ledger; Stripe
	// says most failures arrive within a few business days, and 30 days
	// leaves a wide margin.
	StripePayoutBounceWindow = 30 * 24 * time.Hour
)

// WalletHash binds the confirm call to the planned wallet list.
func WalletHash(wallets []string) string {
	h := sha256.Sum256([]byte("erasure-wallets-v1:" + strings.Join(NormalizeWallets(wallets), "\n")))
	return hex.EncodeToString(h[:])
}

// TokenHash is the stored form of a confirm token.
func TokenHash(token string) string {
	h := sha256.Sum256([]byte("erasure-confirm-v1:" + token))
	return hex.EncodeToString(h[:])
}

// TokenValid reports whether token matches the stored hash before expires.
func TokenValid(storedHash string, expires *time.Time, token string, now time.Time) bool {
	if storedHash == "" || token == "" || expires == nil || !now.Before(*expires) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(storedHash), []byte(TokenHash(token))) == 1
}

// NormalizeEmail is the form in which the confirming email must equal the
// account email: case and surrounding space do not count.
func NormalizeEmail(email string) string { return strings.ToLower(strings.TrimSpace(email)) }
