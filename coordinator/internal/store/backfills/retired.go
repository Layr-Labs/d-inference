package backfills

// retiredBackfills are the one-shot data migrations that coordinators up to
// v0.9.10 ran at boot and later builds no longer carry. Each rebuilt state
// from the rows in dataTable that the current write paths only maintain going
// forward:
//   - backfill_withdrawable_balance_v1 added balances.withdrawable_micro_usd
//     and reconstructed it from the ledger;
//   - backfill_usage_totals_v1 created the usage_totals counter row from the
//     usage history;
//   - backfill_earnings_summary_v1 built earnings_summary from
//     provider_earnings.
//
// The table names are constants spliced into SQL; never feed input here.
var Retired = []struct{ ID, DataTable string }{
	{"backfill_withdrawable_balance_v1", "balances"},
	{"backfill_usage_totals_v1", "usage"},
	{"backfill_earnings_summary_v1", "provider_earnings"},
}
