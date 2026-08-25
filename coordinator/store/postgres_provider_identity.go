package store

import (
	"context"
	"fmt"
	"sort"
)

// providerIdentityBackfillMigration recovers the provider key added after the
// original earnings/session schemas. Every relationship is constrained by both
// the immutable session/provider ID and account ownership. Conflicting mappings
// are deliberately left empty rather than guessed.
//
// The summary update is additive only for rows whose empty key is recovered in
// this transaction, so concurrent normal credits cannot be overwritten.
const providerIdentityBackfillMigration = `DO $$ BEGIN
	LOCK TABLE schema_migrations IN SHARE ROW EXCLUSIVE MODE;
	IF NOT EXISTS (
		SELECT 1 FROM schema_migrations
		WHERE id = 'backfill_provider_earning_identity_v1'
	) THEN
		UPDATE provider_sessions ps
		   SET provider_key = p.public_key
		  FROM providers p
		 WHERE ps.provider_key = ''
		   AND p.public_key <> ''
		   AND p.id = ps.session_id
		   AND p.account_id = ps.account_id
		   AND p.account_id <> ''
		   AND (
		       ps.serial_number = ''
		       OR p.serial_number = ''
		       OR ps.serial_number = p.serial_number
		   );

		WITH identity_map AS (
			SELECT session_id AS provider_id, account_id, provider_key
			  FROM provider_sessions
			 WHERE account_id <> '' AND provider_key <> ''
			UNION ALL
			SELECT p.id, p.account_id, p.public_key
			  FROM providers p
			 WHERE p.account_id <> ''
			   AND p.public_key <> ''
			   AND NOT EXISTS (
			       SELECT 1
			         FROM provider_sessions ps
			        WHERE ps.session_id = p.id
			          AND ps.account_id = p.account_id
			          AND ps.serial_number <> ''
			          AND p.serial_number <> ''
			          AND ps.serial_number <> p.serial_number
			   )
		), unambiguous_identity AS (
			SELECT provider_id, account_id, MIN(provider_key) AS provider_key
			  FROM identity_map
			 GROUP BY provider_id, account_id
			HAVING COUNT(DISTINCT provider_key) = 1
		), recovered AS (
			UPDATE provider_earnings pe
			   SET provider_key = identity.provider_key
			  FROM unambiguous_identity identity
			 WHERE pe.provider_key = ''
			   AND pe.provider_id = identity.provider_id
			   AND pe.account_id = identity.account_id
			RETURNING pe.provider_key, pe.model, pe.amount_micro_usd,
			          pe.prompt_tokens, pe.completion_tokens
		), deltas AS (
			SELECT provider_key,
			       COUNT(*) FILTER (WHERE model <> 'base_reward') AS total_count,
			       COALESCE(SUM(amount_micro_usd), 0) AS total_micro_usd,
			       COALESCE(SUM(prompt_tokens), 0) AS total_prompt_tokens,
			       COALESCE(SUM(completion_tokens), 0) AS total_completion_tokens
			  FROM recovered
			 GROUP BY provider_key
		)
		INSERT INTO earnings_summary (
			key, key_type, total_count, total_micro_usd,
			total_prompt_tokens, total_completion_tokens, updated_at
		)
		SELECT provider_key, 'provider', total_count, total_micro_usd,
		       total_prompt_tokens, total_completion_tokens, NOW()
		  FROM deltas
		ON CONFLICT (key, key_type) DO UPDATE SET
			total_count = earnings_summary.total_count + EXCLUDED.total_count,
			total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			updated_at = NOW();

		INSERT INTO schema_migrations (id)
		VALUES ('backfill_provider_earning_identity_v1');
	END IF;
END $$`

func (s *PostgresStore) ListProviderSessionIdentities(
	ctx context.Context,
	accountID string,
	refs []ProviderEarningIdentityRef,
) ([]ProviderSessionIdentity, error) {
	providerIDs, providerKeys := providerIdentityRefColumns(refs)
	if accountID == "" || len(providerIDs) == 0 {
		return []ProviderSessionIdentity{}, nil
	}

	rows, err := s.pool.Query(ctx, `
		WITH requested AS (
			SELECT provider_id, provider_key, ordinal
			  FROM unnest($2::text[], $3::text[]) WITH ORDINALITY
			       AS ref(provider_id, provider_key, ordinal)
			 WHERE provider_id <> '' OR provider_key <> ''
		), candidates AS (
			SELECT ref.ordinal,
			       ps.session_id,
			       ps.provider_key,
			       ps.serial_number,
			       CASE WHEN ref.provider_id <> '' AND ps.session_id = ref.provider_id THEN 0 ELSE 1 END AS match_rank,
			       0 AS source_rank,
			       ps.last_seen
			  FROM requested ref
			  JOIN provider_sessions ps
			    ON ps.account_id = $1
			   AND ps.serial_number <> ''
			   AND (
			       (ref.provider_id <> '' AND ps.session_id = ref.provider_id)
			       OR (ref.provider_key <> '' AND ps.provider_key = ref.provider_key)
			   )
			UNION ALL
			SELECT ref.ordinal,
			       p.id,
			       p.public_key,
			       p.serial_number,
			       CASE WHEN ref.provider_id <> '' AND p.id = ref.provider_id THEN 0 ELSE 1 END,
			       1,
			       p.last_seen
			  FROM requested ref
			  JOIN providers p
			    ON p.account_id = $1
			   AND p.serial_number <> ''
			   AND (
			       (ref.provider_id <> '' AND p.id = ref.provider_id)
			       OR (ref.provider_key <> '' AND p.public_key = ref.provider_key)
			   )
		)
		SELECT DISTINCT ON (ordinal) session_id, provider_key, serial_number
		  FROM candidates
		 ORDER BY ordinal, match_rank, source_rank, last_seen DESC`,
		accountID, providerIDs, providerKeys,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list provider session identities: %w", err)
	}
	defer rows.Close()

	bySession := make(map[string]ProviderSessionIdentity, len(refs))
	keyOwner := make(map[string]string, len(refs))
	for rows.Next() {
		var identity ProviderSessionIdentity
		if err := rows.Scan(
			&identity.SessionID,
			&identity.ProviderKey,
			&identity.SerialNumber,
		); err != nil {
			return nil, fmt.Errorf("store: scan provider session identity: %w", err)
		}

		if existing, ok := bySession[identity.SessionID]; ok {
			if existing.ProviderKey == "" && identity.ProviderKey != "" {
				if owner, claimed := keyOwner[identity.ProviderKey]; !claimed || owner == identity.SessionID {
					existing.ProviderKey = identity.ProviderKey
					bySession[identity.SessionID] = existing
					keyOwner[identity.ProviderKey] = identity.SessionID
				}
			}
			continue
		}
		if identity.ProviderKey != "" {
			if _, claimed := keyOwner[identity.ProviderKey]; claimed {
				continue
			}
			keyOwner[identity.ProviderKey] = identity.SessionID
		}
		bySession[identity.SessionID] = identity
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate provider session identities: %w", err)
	}

	sessionIDs := make([]string, 0, len(bySession))
	for sessionID := range bySession {
		sessionIDs = append(sessionIDs, sessionID)
	}
	sort.Strings(sessionIDs)
	identities := make([]ProviderSessionIdentity, 0, len(sessionIDs))
	for _, sessionID := range sessionIDs {
		identities = append(identities, bySession[sessionID])
	}
	return identities, nil
}

func providerIdentityRefColumns(refs []ProviderEarningIdentityRef) ([]string, []string) {
	providerIDs := make([]string, 0, len(refs))
	providerKeys := make([]string, 0, len(refs))
	seen := make(map[ProviderEarningIdentityRef]struct{}, len(refs))
	for _, ref := range refs {
		if ref.ProviderID == "" && ref.ProviderKey == "" {
			continue
		}
		if _, ok := seen[ref]; ok {
			continue
		}
		seen[ref] = struct{}{}
		providerIDs = append(providerIDs, ref.ProviderID)
		providerKeys = append(providerKeys, ref.ProviderKey)
	}
	return providerIDs, providerKeys
}
