-- Soft delete: a row with deleted_at set belongs to an erased account and is
-- hidden from every live read. Each ALTER commits on its own, so only one
-- table lock is held at a time. A nullable column with no default changes
-- only the catalog.
-- +goose NO TRANSACTION
-- +goose Up
ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE providers ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
