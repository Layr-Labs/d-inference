package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/attestrecord"
)

func (s *Store) AdvanceCodeAttestationCoverage(ctx context.Context, rows []contracts.CodeAttestation) error {
	valid := make([]contracts.CodeAttestation, 0, len(rows))
	for _, r := range rows {
		if attestrecord.ValidCodeCoverage(r) {
			valid = append(valid, r)
		}
	}
	if len(valid) == 0 {
		return nil
	}
	payload, err := json.Marshal(valid)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err = s.pool.Exec(ctx, `WITH observed AS (
 SELECT * FROM jsonb_to_recordset($1::jsonb) AS x(se_pubkey text, version text,
 attested_at timestamptz, apns_token text, node_public_key text, binary_hash text,
 continuous_coverage_until timestamptz))
 UPDATE code_attestations c SET continuous_coverage_until = GREATEST(c.continuous_coverage_until,o.continuous_coverage_until)
 FROM observed o WHERE c.se_pubkey=o.se_pubkey AND c.version=o.version
 AND c.attested_at=o.attested_at AND c.apns_token=o.apns_token
 AND c.node_public_key=o.node_public_key AND c.binary_hash=o.binary_hash`, payload)
	if err != nil {
		return fmt.Errorf("store: advance code-attestation coverage: %w", err)
	}
	return nil
}
