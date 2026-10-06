package erasure

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// Keys are the keys the scrub collects before it changes anything. Every
// scrub statement is bounded by one of them.
type Keys struct {
	AccountID       string
	ConsumerKeyHash string
	// StripeAccountIDs are the current Express account and every earlier one
	// the account's withdrawals used.
	StripeAccountIDs []string

	ProviderIDs []string
	// SEKeys and AppAttestKeyIDs exclude keys that another account also uses
	// (counted in SharedSEKeys and SharedAppAttestKeys); their rows stay.
	SEKeys              []string
	SharedSEKeys        int64
	Serials             []string
	AppAttestKeyIDs     []string
	SharedAppAttestKeys int64

	ReferrerCode        string
	ReferrerReplacement string
	PrivyReplacement    string

	CheckoutSessionIDs []string
	// RecipientIDs are the current Global Payouts recipient and every earlier
	// one the account's payouts used.
	RecipientIDs             []string
	GlobalRecipientTombstone []byte

	MDADigestsToDelete []string
	MDADigestsShared   int64

	Wallets []WalletReplacement
}

// WalletReplacement is one wallet address and the random value that
// replaces it in every row.
type WalletReplacement struct {
	Address     string
	Replacement string
}

// erasedValue is a fresh random replacement value.
func erasedValue(prefix string) string { return prefix + uuid.NewString() }

// MDASerialDigest matches MachineObservation.Aliases for kind mda_serial.
func MDASerialDigest(serial string) string {
	h := sha256.Sum256([]byte("mda_serial\x00" + serial))
	return hex.EncodeToString(h[:])
}

// LegacySEDigest matches the authenticated account-scoped inventory alias.
func LegacySEDigest(key string) string {
	h := sha256.Sum256([]byte("legacy_se\x00" + key))
	return hex.EncodeToString(h[:])
}

// NormalizeWallets trims, drops empty and duplicate addresses and sorts them.
func NormalizeWallets(in []string) []string {
	trimmed := make([]string, 0, len(in))
	for _, a := range in {
		trimmed = append(trimmed, strings.TrimSpace(a))
	}
	return SortedUnique(trimmed)
}

// SortedUnique returns the non-empty values once each, sorted.
func SortedUnique(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, v := range in {
		if v != "" && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

// NewKeys returns the keys that need no store read: the account hashes,
// fresh replacement values and the planned wallet addresses.
func NewKeys(accountID string, wallets []string) *Keys {
	k := &Keys{
		AccountID:           accountID,
		ConsumerKeyHash:     store.HashKey(accountID),
		PrivyReplacement:    erasedValue("erased:"),
		ReferrerReplacement: erasedValue("erased-"),
	}
	for _, w := range NormalizeWallets(wallets) {
		k.Wallets = append(k.Wallets, WalletReplacement{Address: w, Replacement: erasedValue("erased-")})
	}
	return k
}

// StripeObjects lists the Stripe objects of the account for the plan.
func (k *Keys) StripeObjects() []store.ErasureStripeObject {
	out := []store.ErasureStripeObject{}
	for _, id := range k.StripeAccountIDs {
		out = append(out, store.ErasureStripeObject{Target: store.ErasureTargetStripeAccount, ID: id})
	}
	for _, id := range k.RecipientIDs {
		out = append(out, store.ErasureStripeObject{Target: store.ErasureTargetGlobalRecipient, ID: id})
	}
	for _, id := range k.CheckoutSessionIDs {
		out = append(out, store.ErasureStripeObject{Target: store.ErasureTargetCheckoutSessions, ID: id})
	}
	return out
}

// OutboxRows splits the Stripe objects into outbox rows: one per account,
// one per batch of Checkout Sessions, and one erasure_log row.
func (k *Keys) OutboxRows() []store.ErasureOutboxItem {
	var out []store.ErasureOutboxItem
	add := func(t store.ErasureTarget, id string) {
		out = append(out, store.ErasureOutboxItem{ID: uuid.NewString(), Target: t, ExternalID: id, State: store.ErasureOutboxPending})
	}
	for _, id := range k.StripeAccountIDs {
		add(store.ErasureTargetStripeAccount, id)
	}
	for _, id := range k.RecipientIDs {
		add(store.ErasureTargetGlobalRecipient, id)
	}
	for i := 0; i < len(k.CheckoutSessionIDs); i += store.ErasureCheckoutBatch {
		end := min(i+store.ErasureCheckoutBatch, len(k.CheckoutSessionIDs))
		add(store.ErasureTargetCheckoutSessions, strings.Join(k.CheckoutSessionIDs[i:end], ","))
	}
	add(store.ErasureTargetErasureLog, "")
	return out
}

// StripeObjectCounts is the stored, ID-free form of StripeObjects.
func StripeObjectCounts(objects []store.ErasureStripeObject) map[store.ErasureTarget]int64 {
	if len(objects) == 0 {
		return nil
	}
	out := map[store.ErasureTarget]int64{}
	for _, o := range objects {
		out[o.Target]++
	}
	return out
}

// Retained lists the data the scrub keeps for the account on purpose.
func (k *Keys) Retained() []store.ErasureRetained {
	var out []store.ErasureRetained
	if k.MDADigestsShared > 0 {
		out = append(out, store.ErasureRetained{Table: "darkbloom_machine_aliases", Rows: k.MDADigestsShared, Reason: retainedSharedMDAAlias})
	}
	if k.SharedSEKeys > 0 {
		out = append(out, store.ErasureRetained{Table: "provider_trust_reuse, provider_verification_jobs, code_attestations, code_attest_push_budgets", Rows: k.SharedSEKeys, Reason: retainedSharedSEKey})
	}
	if k.SharedAppAttestKeys > 0 {
		out = append(out, store.ErasureRetained{Table: "app_attest_receipts, app_attest_receipt_blobs, app_attest_receipt_jobs", Rows: k.SharedAppAttestKeys, Reason: retainedSharedAppAttestKey})
	}
	return out
}

// WithoutKeys removes shared from keys and reports how many it removed.
func WithoutKeys(keys, shared []string) ([]string, int64) {
	drop := map[string]bool{}
	for _, s := range shared {
		drop[s] = true
	}
	out := keys[:0:0]
	for _, k := range keys {
		if !drop[k] {
			out = append(out, k)
		}
	}
	return out, int64(len(keys) - len(out))
}
