package postgres

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const legacyMDMCohortDDL = `
CREATE TABLE IF NOT EXISTS legacy_mdm_cohort_freeze (
 singleton BOOLEAN PRIMARY KEY CHECK (singleton), cutoff TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS legacy_mdm_cohort (
 account_id TEXT NOT NULL CHECK (account_id <> ''),
 se_public_key TEXT NOT NULL CHECK (se_public_key <> ''),
 serial_number TEXT NOT NULL CHECK (serial_number <> ''),
 PRIMARY KEY (account_id, se_public_key, serial_number)
);`

var _ store.LegacyMDMCohortStore = (*PostgresStore)(nil)

func (s *PostgresStore) FreezeLegacyMDMCohort(ctx context.Context) ([]store.LegacyMDMMachine, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// Serialize upgraded coordinators, including an empty first freeze.
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952702)`); err != nil {
		return nil, err
	}
	var frozen bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM legacy_mdm_cohort_freeze)`).Scan(&frozen); err != nil {
		return nil, err
	}
	if !frozen {
		// Hold the historical evidence and account-scoped bindings stable through
		// commit. Aliases can come from live observations or historical backfill;
		// verified_at tracks refreshes, not fresh account-token authentication.
		if _, err = tx.Exec(ctx, `LOCK TABLE providers, users, provider_trust_reuse, darkbloom_machine_aliases IN SHARE MODE`); err != nil {
			return nil, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO legacy_mdm_cohort_freeze VALUES (TRUE, clock_timestamp())`); err != nil {
			return nil, err
		}
		_, err = tx.Exec(ctx, `WITH qualified AS (
		 SELECT DISTINCT p.account_id, p.se_public_key, p.serial_number
		 FROM providers p JOIN users u ON u.account_id=p.account_id
		 CROSS JOIN legacy_mdm_cohort_freeze f
		 JOIN darkbloom_machine_aliases a ON a.kind='legacy_se' AND a.scope=p.account_id
		 AND a.digest=encode(sha256(convert_to('legacy_se','UTF8') || '\x00'::bytea || convert_to(p.se_public_key,'UTF8')), 'hex')
		 LEFT JOIN provider_trust_reuse r ON r.se_pubkey=p.se_public_key AND r.serial=p.serial_number
		 WHERE p.account_id<>'' AND p.se_public_key<>'' AND p.serial_number<>''
			 AND u.created_at<f.cutoff AND p.registered_at<f.cutoff
			 AND ((r.mda_udid<>'' AND r.sip_enabled AND r.secure_boot_full
			 AND r.hardware_proof_verified_at>'0001-01-01T00:00:00Z'::timestamptz AND r.hardware_proof_verified_at<f.cutoff)
		 OR (p.trust_level='hardware' AND p.attested
		 AND p.attestation_result->'Valid'='true'::jsonb
		 AND p.attestation_result->'SecureEnclaveAvailable'='true'::jsonb
		 AND p.attestation_result->'SIPEnabled'='true'::jsonb
		 AND p.attestation_result->'SecureBootEnabled'='true'::jsonb
		 AND p.attestation_result->'PublicKey'=to_jsonb(p.se_public_key)
		 AND p.attestation_result->'SerialNumber'=to_jsonb(p.serial_number))))
		 INSERT INTO legacy_mdm_cohort
		 SELECT q.account_id,q.se_public_key,q.serial_number FROM qualified q
		 WHERE NOT EXISTS (SELECT 1 FROM qualified other
		 WHERE other.account_id=q.account_id AND other.se_public_key=q.se_public_key
		 AND other.serial_number<>q.serial_number)`)
		if err != nil {
			return nil, fmt.Errorf("freeze legacy MDM cohort: %w", err)
		}
	}
	rows, err := tx.Query(ctx, `SELECT account_id,se_public_key,serial_number FROM legacy_mdm_cohort ORDER BY account_id,se_public_key,serial_number`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	machines := []store.LegacyMDMMachine{}
	for rows.Next() {
		var m store.LegacyMDMMachine
		if err = rows.Scan(&m.AccountID, &m.SEPublicKey, &m.SerialNumber); err != nil {
			return nil, err
		}
		machines = append(machines, m)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return machines, nil
}
