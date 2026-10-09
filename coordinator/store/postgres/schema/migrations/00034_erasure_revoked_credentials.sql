-- Record which API keys and provider tokens an erasure confirm revoked, so
-- that a cancel restores only those. A request confirmed before this version
-- keeps credential_provenance 0 and has no rows: its cancel restores no
-- credential. Every statement is additive and can run again.
-- +goose Up
ALTER TABLE erasure_requests ADD COLUMN IF NOT EXISTS credential_provenance smallint DEFAULT 0 NOT NULL;
CREATE TABLE IF NOT EXISTS erasure_revoked_credentials (
    request_id text NOT NULL REFERENCES erasure_requests(id),
    kind text NOT NULL CHECK (kind IN ('api_key', 'provider_token')),
    credential_id text NOT NULL,
    PRIMARY KEY (request_id, kind, credential_id)
);
CREATE INDEX IF NOT EXISTS erasure_revoked_credentials_credential ON erasure_revoked_credentials (kind, credential_id);
