-- +goose Up
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_privy_user_id_key;
