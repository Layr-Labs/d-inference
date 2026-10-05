-- name: InsertAPIKey :exec
INSERT INTO api_keys
	(id, key_hash, raw_prefix, owner_account_id, name, active,
	 limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
	 allowed_models, expires_at, created_at, self_route_only)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15);

-- name: InsertAPIKeyIfAbsent :exec
INSERT INTO api_keys
	(id, key_hash, raw_prefix, owner_account_id, name, active,
	 limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
	 allowed_models, expires_at, created_at, self_route_only)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
ON CONFLICT (key_hash) DO NOTHING;

-- name: GetActiveKeyAccount :one
SELECT owner_account_id FROM api_keys WHERE key_hash = $1 AND active = TRUE;

-- name: GetAPIKeyByHash :one
SELECT * FROM api_keys WHERE key_hash = $1;

-- name: ListAPIKeysByOwner :many
SELECT * FROM api_keys WHERE owner_account_id = $1 AND id <> '' ORDER BY created_at DESC;

-- name: GetAPIKeyByID :one
SELECT * FROM api_keys WHERE id = $1 AND owner_account_id = $2;

-- name: GetAPIKeyByIDForUpdate :one
SELECT * FROM api_keys WHERE id = $1 AND owner_account_id = $2 FOR UPDATE;

-- name: UpdateAPIKey :execrows
UPDATE api_keys SET
	name = $1, active = $2, limit_micro_usd = $3, limit_reset = $4,
	rpm_limit = $5, itpm_limit = $6, otpm_limit = $7,
	allowed_models = $8, expires_at = $9, self_route_only = $10
WHERE id = $11 AND owner_account_id = $12;

-- name: DeleteAPIKeyByID :execrows
DELETE FROM api_keys WHERE id = $1 AND owner_account_id = $2;

-- name: TouchAPIKey :exec
UPDATE api_keys SET last_used_at = $1 WHERE id = $2;

-- name: KeySpendSince :one
SELECT COALESCE(SUM(cost_micro_usd), 0)::bigint AS total_micro_usd FROM usage
WHERE key_id = sqlc.arg('key_id')
  AND (sqlc.narg('since')::timestamptz IS NULL OR created_at >= sqlc.narg('since'));

-- name: DeactivateAPIKeyByHash :execrows
UPDATE api_keys SET active = FALSE WHERE key_hash = $1 AND active = TRUE;
