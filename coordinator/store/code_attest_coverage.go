package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

func cloneCodeAttestation(r CodeAttestation) CodeAttestation {
	if r.ContinuousCoverageUntil != nil {
		t := *r.ContinuousCoverageUntil
		r.ContinuousCoverageUntil = &t
	}
	return r
}

func validCodeCoverage(r CodeAttestation) bool {
	return r.SEPubKey != "" && r.Version != "" && r.APNsToken != "" && r.NodePublicKey != "" && r.BinaryHash != "" && !r.AttestedAt.IsZero() && r.ContinuousCoverageUntil != nil && !r.ContinuousCoverageUntil.Before(r.AttestedAt)
}

func sameCodeProof(a, b CodeAttestation) bool {
	return a.SEPubKey == b.SEPubKey && a.Version == b.Version && a.APNsToken == b.APNsToken && a.NodePublicKey == b.NodePublicKey && a.BinaryHash == b.BinaryHash && a.AttestedAt.Equal(b.AttestedAt)
}

// AdvanceCodeAttestationCoverage never inserts or replaces proof. A delayed
// coverage write cannot resurrect a deleted proof or cover a different process.
func (s *MemoryStore) AdvanceCodeAttestationCoverage(_ context.Context, rows []CodeAttestation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range rows {
		old, ok := s.codeAttestations[r.SEPubKey]
		if !ok || !validCodeCoverage(r) || !sameCodeProof(old, r) {
			continue
		}
		if old.ContinuousCoverageUntil == nil || r.ContinuousCoverageUntil.After(*old.ContinuousCoverageUntil) {
			old.ContinuousCoverageUntil = r.ContinuousCoverageUntil
			s.codeAttestations[r.SEPubKey] = cloneCodeAttestation(old)
		}
	}
	return nil
}

func (s *PostgresStore) AdvanceCodeAttestationCoverage(ctx context.Context, rows []CodeAttestation) error {
	valid := make([]CodeAttestation, 0, len(rows))
	for _, r := range rows {
		if validCodeCoverage(r) {
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
