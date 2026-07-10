\set ON_ERROR_STOP on

-- Read-only preflight for withdrawable-balance reconciliation.
--
-- Historical generic refund entries do not preserve how much withdrawable
-- provenance they restored, so no automatic backfill can reconstruct the
-- correct value. This report identifies accounts requiring an explicit,
-- journaled operator decision before Rust shares the database.

BEGIN TRANSACTION READ ONLY;

-- Hard invariant violations must be repaired before any cutover.
SELECT account_id, balance_micro_usd, withdrawable_micro_usd
FROM balances
WHERE withdrawable_micro_usd < 0
   OR withdrawable_micro_usd > balance_micro_usd
ORDER BY account_id;

-- Review candidates: the old startup backfill could repopulate these from
-- historical earnings after those earnings were already spent/withdrawn.
SELECT
    b.account_id,
    b.balance_micro_usd,
    b.withdrawable_micro_usd,
    COALESCE(SUM(le.amount_micro_usd) FILTER (
        WHERE le.entry_type IN ('payout', 'referral_reward', 'admin_reward', 'stripe_payout')
    ), 0) AS historical_withdrawable_credits,
    COALESCE(SUM(le.amount_micro_usd) FILTER (
        WHERE le.entry_type = 'stripe_deposit'
    ), 0) AS historical_nonwithdrawable_deposits
FROM balances b
LEFT JOIN ledger_entries le ON le.account_id = b.account_id
GROUP BY b.account_id, b.balance_micro_usd, b.withdrawable_micro_usd
HAVING b.balance_micro_usd > 0
   AND (
       b.withdrawable_micro_usd = 0
       OR b.withdrawable_micro_usd > b.balance_micro_usd
   )
ORDER BY b.account_id;

-- Fleet-wide conservation snapshot to attach to the reviewed adjustment.
SELECT
    COUNT(*) AS accounts,
    COALESCE(SUM(balance_micro_usd), 0) AS total_balance_micro_usd,
    COALESCE(SUM(withdrawable_micro_usd), 0) AS total_withdrawable_micro_usd
FROM balances;

ROLLBACK;
