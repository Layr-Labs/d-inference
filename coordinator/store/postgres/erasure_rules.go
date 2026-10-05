package postgres

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
)

// This file is the PostgreSQL form of the rule table in
// coordinator/internal/store/erasure/rules.go: for every rule, the scrub
// statements bounded by the collected keys. ScrubAccount runs them in the
// table's order.

// piiStatement is one scrub statement and the count query with the same
// predicate. The scrub runs count, then apply, in one transaction and
// aborts when the two differ.
type piiStatement struct {
	count func(context.Context, *storedb.Queries) (int64, error)
	apply func(context.Context, *storedb.Queries) (int64, error)
}

// one wraps a single statement.
func one(count, apply func(context.Context, *storedb.Queries) (int64, error)) []piiStatement {
	return []piiStatement{{count: count, apply: apply}}
}

// byKey is one statement whose count and apply queries take the same key.
func byKey(key string, count, apply func(*storedb.Queries, context.Context, string) (int64, error)) []piiStatement {
	return one(
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, key) },
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, key) })
}

// byKeys is one statement whose count and apply queries take the same key
// list; none when the list is empty.
func byKeys(keys []string, count, apply func(*storedb.Queries, context.Context, []string) (int64, error)) []piiStatement {
	if len(keys) == 0 {
		return nil
	}
	return one(
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, keys) },
		func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, keys) })
}

// erasureStatements maps every rule name in erasure.Rules to its statements
// for the collected keys; none when the account has no linked keys of that
// kind.
var erasureStatements = map[string]func(k *erasure.Keys) []piiStatement{
	"users": func(k *erasure.Keys) []piiStatement {
		return one(
			func(ctx context.Context, q *storedb.Queries) (int64, error) { return q.CountUsersRow(ctx, k.AccountID) },
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.ScrubUsersRow(ctx, storedb.ScrubUsersRowParams{AccountID: k.AccountID, PrivyUserID: k.PrivyReplacement})
			})
	},
	"api_keys": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountAPIKeysRows, (*storedb.Queries).ScrubAPIKeysRows)
	},
	"provider_tokens": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountProviderTokensRows, (*storedb.Queries).ScrubProviderTokensRows)
	},
	"device_codes": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountDeviceCodesRows, (*storedb.Queries).DeleteDeviceCodesRows)
	},
	"providers": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountProvidersRows, (*storedb.Queries).ScrubProvidersRows)
	},
	"provider_sessions": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountProviderSessionsRows, (*storedb.Queries).ScrubProviderSessionsRows)
	},
	"provider_log_reports": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountProviderLogReportsRows, (*storedb.Queries).DeleteProviderLogReportsRows)
	},
	"provider_trust_reuse": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.SEKeys, (*storedb.Queries).CountProviderTrustReuseRows, (*storedb.Queries).DeleteProviderTrustReuseRows)
	},
	"provider_verification_jobs": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.SEKeys, (*storedb.Queries).CountProviderVerificationJobsRows, (*storedb.Queries).DeleteProviderVerificationJobsRows)
	},
	"code_attestations": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.SEKeys, (*storedb.Queries).CountCodeAttestationsRows, (*storedb.Queries).DeleteCodeAttestationsRows)
	},
	"code_attest_push_budgets": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.SEKeys, (*storedb.Queries).CountCodeAttestPushBudgetsRows, (*storedb.Queries).DeleteCodeAttestPushBudgetsRows)
	},
	"machine_aliases_account": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountAccountMachineAliasesRows, (*storedb.Queries).DeleteAccountMachineAliasesRows)
	},
	"machine_aliases_mda_serial": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.MDADigestsToDelete, (*storedb.Queries).CountMDASerialAliasesRows, (*storedb.Queries).DeleteMDASerialAliasesRows)
	},
	"app_attest_evidence_blobs": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.ProviderIDs, (*storedb.Queries).CountAppAttestEvidenceBlobsRows, (*storedb.Queries).DeleteAppAttestEvidenceBlobsRows)
	},
	"app_attest_evidence": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.ProviderIDs, (*storedb.Queries).CountAppAttestEvidenceRows, (*storedb.Queries).ScrubAppAttestEvidenceRows)
	},
	"app_attest_receipt_jobs": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptJobsRows, (*storedb.Queries).DeleteAppAttestReceiptJobsRows)
	},
	"app_attest_receipt_blobs": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptBlobsRows, (*storedb.Queries).DeleteAppAttestReceiptBlobsRows)
	},
	"app_attest_receipts": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.AppAttestKeyIDs, (*storedb.Queries).CountAppAttestReceiptsRows, (*storedb.Queries).ScrubAppAttestReceiptsRows)
	},
	"usage_request_location": func(k *erasure.Keys) []piiStatement {
		return byKey(k.ConsumerKeyHash, (*storedb.Queries).CountUsageLocationRows, (*storedb.Queries).ScrubUsageLocationRows)
	},
	"inference_routes_consumer_region": func(k *erasure.Keys) []piiStatement {
		return byKey(k.ConsumerKeyHash, (*storedb.Queries).CountConsumerRegionRows, (*storedb.Queries).ScrubConsumerRegionRows)
	},
	"inference_routes_provider_region": func(k *erasure.Keys) []piiStatement {
		return byKeys(k.ProviderIDs, (*storedb.Queries).CountProviderRegionRows, (*storedb.Queries).ScrubProviderRegionRows)
	},
	"referrers": func(k *erasure.Keys) []piiStatement {
		return one(
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.CountReferrersRow(ctx, k.AccountID)
			},
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.ScrubReferrersRow(ctx, storedb.ScrubReferrersRowParams{AccountID: k.AccountID, Code: k.ReferrerReplacement})
			})
	},
	"billing_sessions_referral_code": func(k *erasure.Keys) []piiStatement {
		if k.ReferrerCode == "" {
			return nil
		}
		return one(
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.CountReferralCodeCopies(ctx, k.ReferrerCode)
			},
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.ScrubReferralCodeCopies(ctx, storedb.ScrubReferralCodeCopiesParams{OldCode: k.ReferrerCode, NewCode: k.ReferrerReplacement})
			})
	},
	"billing_sessions": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountBillingSessionsRows, (*storedb.Queries).ScrubBillingSessionsRows)
	},
	"ledger_entries_stripe_reference": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountStripeLedgerReferences, (*storedb.Queries).ScrubStripeLedgerReferences)
	},
	"ledger_entries_admin_note": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountAdminNoteLedgerReferences, (*storedb.Queries).ScrubAdminNoteLedgerReferences)
	},
	"global_payout_recipients": func(k *erasure.Keys) []piiStatement {
		return one(
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.CountGlobalRecipientRow(ctx, k.AccountID)
			},
			func(ctx context.Context, q *storedb.Queries) (int64, error) {
				return q.TombstoneGlobalRecipientRow(ctx, storedb.TombstoneGlobalRecipientRowParams{AccountID: k.AccountID, Data: k.GlobalRecipientTombstone})
			})
	},
	"global_payout_withdrawals": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountGlobalPayoutRows, (*storedb.Queries).ScrubGlobalPayoutRows)
	},
	"stripe_withdrawals": func(k *erasure.Keys) []piiStatement {
		return byKey(k.AccountID, (*storedb.Queries).CountStripeWithdrawalRows, (*storedb.Queries).ScrubStripeWithdrawalRows)
	},
	"payments_consumer_address": func(k *erasure.Keys) []piiStatement {
		return walletStatements(k, (*storedb.Queries).CountPaymentConsumerAddress,
			func(q *storedb.Queries, ctx context.Context, w erasure.WalletReplacement) (int64, error) {
				return q.ScrubPaymentConsumerAddress(ctx, storedb.ScrubPaymentConsumerAddressParams{Address: w.Address, Replacement: w.Replacement})
			})
	},
	"payments_provider_address": func(k *erasure.Keys) []piiStatement {
		return walletStatements(k, (*storedb.Queries).CountPaymentProviderAddress,
			func(q *storedb.Queries, ctx context.Context, w erasure.WalletReplacement) (int64, error) {
				return q.ScrubPaymentProviderAddress(ctx, storedb.ScrubPaymentProviderAddressParams{Address: w.Address, Replacement: w.Replacement})
			})
	},
	"provider_payouts_address": func(k *erasure.Keys) []piiStatement {
		return walletStatements(k, (*storedb.Queries).CountProviderPayoutAddress,
			func(q *storedb.Queries, ctx context.Context, w erasure.WalletReplacement) (int64, error) {
				return q.ScrubProviderPayoutAddress(ctx, storedb.ScrubProviderPayoutAddressParams{Address: w.Address, Replacement: w.Replacement})
			})
	},
}

// walletStatements returns one statement per wallet address.
func walletStatements(k *erasure.Keys,
	count func(*storedb.Queries, context.Context, string) (int64, error),
	apply func(*storedb.Queries, context.Context, erasure.WalletReplacement) (int64, error),
) []piiStatement {
	out := make([]piiStatement, 0, len(k.Wallets))
	for _, w := range k.Wallets {
		out = append(out, piiStatement{
			count: func(ctx context.Context, q *storedb.Queries) (int64, error) { return count(q, ctx, w.Address) },
			apply: func(ctx context.Context, q *storedb.Queries) (int64, error) { return apply(q, ctx, w) },
		})
	}
	return out
}

// ruleStatements returns the statements of rule for the collected keys.
func ruleStatements(rule erasure.Rule, k *erasure.Keys) ([]piiStatement, error) {
	statements, ok := erasureStatements[rule.Name]
	if !ok {
		return nil, fmt.Errorf("store: no postgres erasure rule %q", rule.Name)
	}
	return statements(k), nil
}

// countRules reads the count query of every rule.
func countRules(ctx context.Context, q *storedb.Queries, k *erasure.Keys) ([]store.ErasureRowCount, error) {
	out := make([]store.ErasureRowCount, 0, len(erasure.Rules))
	for _, rule := range erasure.Rules {
		statements, err := ruleStatements(rule, k)
		if err != nil {
			return nil, err
		}
		var rows int64
		for _, st := range statements {
			n, err := st.count(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure count %s: %w", rule.Name, err)
			}
			rows += n
		}
		out = append(out, rule.RowCount(rows))
	}
	return out, nil
}

// applyRules runs every rule statement and checks its affected rows against
// the count read just before in the same transaction.
func applyRules(ctx context.Context, q *storedb.Queries, k *erasure.Keys) ([]store.ErasureRowCount, error) {
	out := make([]store.ErasureRowCount, 0, len(erasure.Rules))
	for _, rule := range erasure.Rules {
		statements, err := ruleStatements(rule, k)
		if err != nil {
			return nil, err
		}
		var rows int64
		for _, st := range statements {
			want, err := st.count(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure count %s: %w", rule.Name, err)
			}
			got, err := st.apply(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure apply %s: %w", rule.Name, err)
			}
			if got != want {
				return nil, fmt.Errorf("%w: %s counted %d, changed %d", store.ErrErasureCountMismatch, rule.Name, want, got)
			}
			rows += got
		}
		out = append(out, rule.RowCount(rows))
	}
	return out, nil
}
