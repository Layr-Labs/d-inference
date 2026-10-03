-- After an account is erased, no credit may reach its balance: a late
-- payout bounce, a returned Global Payout, a settlement or a referral reward
-- would otherwise refill a forfeited account. Two triggers cover every
-- credit path. The balances triggers keep an increase out of an erased
-- account's balances; the ledger trigger drops the credit's ledger row and
-- records it in erasure_refused_credits for manual review, so the ledger
-- still sums to the balance. The caller sees success and acknowledges, so a
-- webhook is not redelivered. Credits during the grace period still apply
-- (state 'pending'), because the erasure can be canceled. References are
-- stored without free-text admin notes or Checkout Session IDs.
-- +goose Up
CREATE TABLE IF NOT EXISTS erasure_refused_credits (
    id               BIGSERIAL PRIMARY KEY,
    account_id       TEXT NOT NULL,
    entry_type       TEXT NOT NULL,
    amount_micro_usd BIGINT NOT NULL,
    reference        TEXT NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS erasure_refused_credits_account ON erasure_refused_credits (account_id, created_at DESC);

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION erasure_account_erased(account TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM erasure_requests WHERE account_id = account AND state = 'erased');
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION erasure_keep_balance_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.balance_micro_usd > 0 OR NEW.withdrawable_micro_usd > 0)
       AND erasure_account_erased(NEW.account_id) THEN
        NEW.balance_micro_usd := LEAST(NEW.balance_micro_usd, 0);
        NEW.withdrawable_micro_usd := LEAST(NEW.withdrawable_micro_usd, 0);
    END IF;
    RETURN NEW;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION erasure_keep_balance_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.balance_micro_usd > OLD.balance_micro_usd OR NEW.withdrawable_micro_usd > OLD.withdrawable_micro_usd)
       AND erasure_account_erased(NEW.account_id) THEN
        NEW.balance_micro_usd := LEAST(NEW.balance_micro_usd, OLD.balance_micro_usd);
        NEW.withdrawable_micro_usd := LEAST(NEW.withdrawable_micro_usd, OLD.withdrawable_micro_usd);
    END IF;
    RETURN NEW;
END $$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION erasure_refuse_ledger_credit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF erasure_account_erased(NEW.account_id) THEN
        INSERT INTO erasure_refused_credits (account_id, entry_type, amount_micro_usd, reference)
        VALUES (NEW.account_id, NEW.entry_type, NEW.amount_micro_usd,
                CASE WHEN NEW.entry_type IN ('admin_credit', 'admin_reward') THEN NEW.entry_type
                     WHEN NEW.reference LIKE 'stripe:%' THEN 'stripe:erased'
                     ELSE NEW.reference END);
        RETURN NULL;
    END IF;
    RETURN NEW;
END $$;
-- +goose StatementEnd

-- The increase test is in the function bodies, not in WHEN clauses, so the
-- triggers add no catalog dependency on the balance columns.
CREATE OR REPLACE TRIGGER erasure_keep_balance_insert BEFORE INSERT ON balances
    FOR EACH ROW EXECUTE FUNCTION erasure_keep_balance_insert();
CREATE OR REPLACE TRIGGER erasure_keep_balance_update BEFORE UPDATE ON balances
    FOR EACH ROW EXECUTE FUNCTION erasure_keep_balance_update();
CREATE OR REPLACE TRIGGER erasure_refuse_ledger_credit BEFORE INSERT ON ledger_entries
    FOR EACH ROW WHEN (NEW.amount_micro_usd > 0)
    EXECUTE FUNCTION erasure_refuse_ledger_credit();
