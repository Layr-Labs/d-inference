package schema

const GlobalPayoutSchema = `
CREATE TABLE IF NOT EXISTS global_payout_recipients (
 account_id TEXT PRIMARY KEY, country TEXT NOT NULL, data JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS global_payout_withdrawals (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL,
 external_id TEXT NOT NULL DEFAULT '', submitted_at TIMESTAMPTZ NOT NULL,
 checked_at TIMESTAMPTZ NOT NULL, lease_until TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL
);
ALTER TABLE global_payout_withdrawals ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT 'infinity';
UPDATE global_payout_withdrawals SET expires_at=(data->>'expires_at')::timestamptz WHERE status='quoted' AND expires_at='infinity';
CREATE INDEX IF NOT EXISTS global_payout_quote_expiry ON global_payout_withdrawals(expires_at) WHERE status='quoted';
CREATE UNIQUE INDEX IF NOT EXISTS global_payout_external_id ON global_payout_withdrawals(external_id) WHERE external_id <> '';
CREATE INDEX IF NOT EXISTS global_payout_account ON global_payout_withdrawals(account_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS global_payout_reconcile ON global_payout_withdrawals(checked_at) WHERE status IN ('pending','processing','posted');
`
