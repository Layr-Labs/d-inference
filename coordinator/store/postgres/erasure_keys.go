package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func noRows(err error) bool { return errors.Is(err, pgx.ErrNoRows) }

// collectErasureKeys reads every key of the account in q's transaction.
func collectErasureKeys(ctx context.Context, q *storedb.Queries, accountID, stripeAccountID string, wallets []string) (*erasure.Keys, error) {
	k := erasure.NewKeys(accountID, wallets)
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
	historicalIDs, err := q.ListAccountHistoricalProviderIDs(ctx, accountID)
	if err != nil {
		return nil, err
	}
	k.ProviderIDs = erasure.SortedUnique(append(k.ProviderIDs, historicalIDs...))
	k.SEKeys = erasure.SortedUnique(seKeys)
	k.Serials = erasure.SortedUnique(append(append(serials, sessionSerials...), logSerials...))
	if len(k.SEKeys) > 0 {
		shared, err := q.ListSharedSEKeys(ctx, storedb.ListSharedSEKeysParams{SeKeys: k.SEKeys, AccountID: accountID})
		if err != nil {
			return nil, err
		}
		k.SEKeys, k.SharedSEKeys = erasure.WithoutKeys(k.SEKeys, shared)
	}
	if len(k.ProviderIDs) > 0 {
		if k.AppAttestKeyIDs, err = q.ListAppAttestKeysForSessions(ctx, k.ProviderIDs); err != nil {
			return nil, err
		}
		k.AppAttestKeyIDs = erasure.SortedUnique(k.AppAttestKeyIDs)
	}
	if len(k.AppAttestKeyIDs) > 0 {
		shared, err := q.ListSharedAppAttestKeys(ctx, storedb.ListSharedAppAttestKeysParams{KeyIds: k.AppAttestKeyIDs, SessionIds: k.ProviderIDs})
		if err != nil {
			return nil, err
		}
		k.AppAttestKeyIDs, k.SharedAppAttestKeys = erasure.WithoutKeys(k.AppAttestKeyIDs, shared)
	}
	pastAccounts, err := q.ListAccountStripeAccountIDs(ctx, accountID)
	if err != nil {
		return nil, err
	}
	k.StripeAccountIDs = erasure.SortedUnique(append(pastAccounts, stripeAccountID))
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
		var r store.GlobalRecipient
		if err := json.Unmarshal(data, &r); err != nil {
			return nil, err
		}
		pastRecipients = append(pastRecipients, r.RecipientID)
	}
	k.RecipientIDs = erasure.SortedUnique(pastRecipients)
	if k.GlobalRecipientTombstone, err = json.Marshal(store.GlobalRecipient{ID: uuid.NewString(), AccountID: accountID}); err != nil {
		return nil, err
	}

	staged, err := q.ListStagedErasureObjects(ctx, accountID)
	if err != nil {
		return nil, err
	}
	for _, item := range staged {
		switch store.ErasureTarget(item.Target) {
		case store.ErasureTargetStripeAccount:
			k.StripeAccountIDs = append(k.StripeAccountIDs, item.ExternalID)
		case store.ErasureTargetGlobalRecipient:
			k.RecipientIDs = append(k.RecipientIDs, item.ExternalID)
		case store.ErasureTargetCheckoutSessions:
			k.CheckoutSessionIDs = append(k.CheckoutSessionIDs, strings.Split(item.ExternalID, ",")...)
		}
	}
	k.StripeAccountIDs = erasure.SortedUnique(k.StripeAccountIDs)
	k.RecipientIDs = erasure.SortedUnique(k.RecipientIDs)
	k.CheckoutSessionIDs = erasure.SortedUnique(k.CheckoutSessionIDs)

	if len(k.Serials) > 0 {
		digests := make([]string, 0, len(k.Serials))
		for _, s := range k.Serials {
			digests = append(digests, erasure.MDASerialDigest(s))
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
