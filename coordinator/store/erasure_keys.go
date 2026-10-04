package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store/storedb"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// erasureKeys are the keys the scrub collects before it changes anything.
// Every scrub statement is bounded by one of them.
type erasureKeys struct {
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

	Wallets []walletReplacement
}

// walletReplacement is one wallet address and the random value that
// replaces it in every row.
type walletReplacement struct {
	Address     string
	Replacement string
}

// erasedValue is a fresh random replacement value.
func erasedValue(prefix string) string { return prefix + uuid.NewString() }

// mdaSerialDigest matches MachineObservation.aliases for kind mda_serial.
func mdaSerialDigest(serial string) string {
	h := sha256.Sum256([]byte("mda_serial\x00" + serial))
	return hex.EncodeToString(h[:])
}

// normalizeWallets trims, drops empty and duplicate addresses and sorts them.
func normalizeWallets(in []string) []string {
	trimmed := make([]string, 0, len(in))
	for _, a := range in {
		trimmed = append(trimmed, strings.TrimSpace(a))
	}
	return sortedUnique(trimmed)
}

// sortedUnique returns the non-empty values once each, sorted.
func sortedUnique(in []string) []string {
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

func noRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }

// newErasureKeys returns the keys that need no store read: the account
// hashes, fresh replacement values and the planned wallet addresses.
func newErasureKeys(accountID string, wallets []string) *erasureKeys {
	k := &erasureKeys{
		AccountID:           accountID,
		ConsumerKeyHash:     hashKey(accountID),
		PrivyReplacement:    erasedValue("erased:"),
		ReferrerReplacement: erasedValue("erased-"),
	}
	for _, w := range normalizeWallets(wallets) {
		k.Wallets = append(k.Wallets, walletReplacement{Address: w, Replacement: erasedValue("erased-")})
	}
	return k
}

// collectErasureKeys reads every key of the account in q's transaction.
func collectErasureKeys(ctx context.Context, q *storedb.Queries, accountID, stripeAccountID string, wallets []string) (*erasureKeys, error) {
	k := newErasureKeys(accountID, wallets)
	providers, err := q.ListAccountProviderKeys(ctx, accountID)
	if err != nil {
		return nil, err
	}
	var seKeys, serials []string
	for _, p := range providers {
		k.ProviderIDs = append(k.ProviderIDs, p.ID)
		seKeys = append(seKeys, p.SePublicKey)
		serials = append(serials, p.SerialNumber)
	}
	sessionSerials, err := q.ListAccountSessionSerials(ctx, accountID)
	if err != nil {
		return nil, err
	}
	logSerials, err := q.ListAccountLogReportSerials(ctx, accountID)
	if err != nil {
		return nil, err
	}
	k.ProviderIDs = sortedUnique(k.ProviderIDs)
	k.SEKeys = sortedUnique(seKeys)
	k.Serials = sortedUnique(append(append(serials, sessionSerials...), logSerials...))
	if len(k.SEKeys) > 0 {
		shared, err := q.ListSharedSEKeys(ctx, storedb.ListSharedSEKeysParams{SeKeys: k.SEKeys, AccountID: accountID})
		if err != nil {
			return nil, err
		}
		k.SEKeys, k.SharedSEKeys = withoutKeys(k.SEKeys, shared)
	}
	if len(k.ProviderIDs) > 0 {
		if k.AppAttestKeyIDs, err = q.ListAppAttestKeysForSessions(ctx, k.ProviderIDs); err != nil {
			return nil, err
		}
		k.AppAttestKeyIDs = sortedUnique(k.AppAttestKeyIDs)
	}
	if len(k.AppAttestKeyIDs) > 0 {
		shared, err := q.ListSharedAppAttestKeys(ctx, storedb.ListSharedAppAttestKeysParams{KeyIds: k.AppAttestKeyIDs, SessionIds: k.ProviderIDs})
		if err != nil {
			return nil, err
		}
		k.AppAttestKeyIDs, k.SharedAppAttestKeys = withoutKeys(k.AppAttestKeyIDs, shared)
	}
	pastAccounts, err := q.ListAccountStripeAccountIDs(ctx, accountID)
	if err != nil {
		return nil, err
	}
	k.StripeAccountIDs = sortedUnique(append(pastAccounts, stripeAccountID))
	pastRecipients, err := q.ListAccountRecipientIDs(ctx, accountID)
	if err != nil {
		return nil, err
	}

	if k.ReferrerCode, err = q.GetReferrerCodeForErasure(ctx, accountID); err != nil && !noRows(err) {
		return nil, err
	}
	if k.CheckoutSessionIDs, err = q.ListAccountCheckoutSessionIDs(ctx, accountID); err != nil {
		return nil, err
	}
	data, err := q.GetGlobalRecipientDataForErasure(ctx, accountID)
	if err != nil && !noRows(err) {
		return nil, err
	}
	if err == nil {
		var r GlobalRecipient
		if err := json.Unmarshal(data, &r); err != nil {
			return nil, err
		}
		pastRecipients = append(pastRecipients, r.RecipientID)
	}
	k.RecipientIDs = sortedUnique(pastRecipients)
	if k.GlobalRecipientTombstone, err = json.Marshal(GlobalRecipient{ID: uuid.NewString(), AccountID: accountID}); err != nil {
		return nil, err
	}

	if len(k.Serials) > 0 {
		digests := make([]string, 0, len(k.Serials))
		for _, s := range k.Serials {
			digests = append(digests, mdaSerialDigest(s))
		}
		aliases, err := q.ListMDASerialAliasesForErasure(ctx, storedb.ListMDASerialAliasesForErasureParams{AccountID: accountID, Digests: digests})
		if err != nil {
			return nil, err
		}
		for _, a := range aliases {
			if a.Shared {
				k.MDADigestsShared++
			} else {
				k.MDADigestsToDelete = append(k.MDADigestsToDelete, a.Digest)
			}
		}
		sort.Strings(k.MDADigestsToDelete)
	}
	return k, nil
}

// stripeObjects lists the Stripe objects of the account for the plan.
func (k *erasureKeys) stripeObjects() []ErasureStripeObject {
	out := []ErasureStripeObject{}
	for _, id := range k.StripeAccountIDs {
		out = append(out, ErasureStripeObject{Target: ErasureTargetStripeAccount, ID: id})
	}
	for _, id := range k.RecipientIDs {
		out = append(out, ErasureStripeObject{Target: ErasureTargetGlobalRecipient, ID: id})
	}
	for _, id := range k.CheckoutSessionIDs {
		out = append(out, ErasureStripeObject{Target: ErasureTargetCheckoutSessions, ID: id})
	}
	return out
}

// outboxRows splits the Stripe objects into outbox rows: one per account,
// one per batch of Checkout Sessions, and one erasure_log row.
func (k *erasureKeys) outboxRows() []ErasureOutboxItem {
	var out []ErasureOutboxItem
	add := func(t ErasureTarget, id string) {
		out = append(out, ErasureOutboxItem{ID: uuid.NewString(), Target: t, ExternalID: id, State: ErasureOutboxPending})
	}
	for _, id := range k.StripeAccountIDs {
		add(ErasureTargetStripeAccount, id)
	}
	for _, id := range k.RecipientIDs {
		add(ErasureTargetGlobalRecipient, id)
	}
	for i := 0; i < len(k.CheckoutSessionIDs); i += ErasureCheckoutBatch {
		end := min(i+ErasureCheckoutBatch, len(k.CheckoutSessionIDs))
		add(ErasureTargetCheckoutSessions, strings.Join(k.CheckoutSessionIDs[i:end], ","))
	}
	add(ErasureTargetErasureLog, "")
	return out
}

// stripeObjectCounts is the stored, ID-free form of stripeObjects.
func stripeObjectCounts(objects []ErasureStripeObject) map[ErasureTarget]int64 {
	if len(objects) == 0 {
		return nil
	}
	out := map[ErasureTarget]int64{}
	for _, o := range objects {
		out[o.Target]++
	}
	return out
}

// retained lists the data the scrub keeps for the account on purpose.
func (k *erasureKeys) retained() []ErasureRetained {
	var out []ErasureRetained
	if k.MDADigestsShared > 0 {
		out = append(out, ErasureRetained{Table: "darkbloom_machine_aliases", Rows: k.MDADigestsShared, Reason: retainedSharedMDAAlias})
	}
	if k.SharedSEKeys > 0 {
		out = append(out, ErasureRetained{Table: "provider_trust_reuse, provider_verification_jobs, code_attestations, code_attest_push_budgets", Rows: k.SharedSEKeys, Reason: retainedSharedSEKey})
	}
	if k.SharedAppAttestKeys > 0 {
		out = append(out, ErasureRetained{Table: "app_attest_receipts, app_attest_receipt_blobs, app_attest_receipt_jobs", Rows: k.SharedAppAttestKeys, Reason: retainedSharedAppAttestKey})
	}
	return out
}

// withoutKeys removes shared from keys and reports how many it removed.
func withoutKeys(keys, shared []string) ([]string, int64) {
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
