-- Let a referrer code change propagate to referrals. The new foreign key is
-- added NOT VALID (a short lock), validated without blocking writes, and then
-- replaces the old one. Each statement commits on its own; the first one
-- removes a key left by an interrupted earlier attempt.
-- +goose NO TRANSACTION
-- +goose Up
ALTER TABLE referrals DROP CONSTRAINT IF EXISTS referrals_referrer_code_cascade_fkey;
ALTER TABLE referrals ADD CONSTRAINT referrals_referrer_code_cascade_fkey
    FOREIGN KEY (referrer_code) REFERENCES referrers (code) ON UPDATE CASCADE NOT VALID;
ALTER TABLE referrals VALIDATE CONSTRAINT referrals_referrer_code_cascade_fkey;
ALTER TABLE referrals DROP CONSTRAINT IF EXISTS referrals_referrer_code_fkey;
