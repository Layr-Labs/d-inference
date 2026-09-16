package postgres

import (
	"context"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// Historical rows retain their original account attribution and liveness time.
// Only a previously valid, endpoint-bound key becomes a key alias. Historical
// MDA booleans and serial claims never create hardware-verified aliases.
func (s *Store) BackfillMachineInventory(ctx context.Context, limit int) (int, error) {
	if limit < 1 || limit > 100 {
		limit = 100
	}
	rows, err := s.pool.Query(ctx, `SELECT p.id,COALESCE(p.account_id,''),COALESCE(p.se_public_key,''),COALESCE(p.public_key,''),p.attestation_result,COALESCE(p.version,''),p.hardware,p.last_seen
	 FROM providers p LEFT JOIN darkbloom_machine_sessions m ON m.session_id=p.id WHERE m.session_id IS NULL ORDER BY p.id LIMIT $1`, limit)
	if err != nil {
		return 0, err
	}
	var observations []contracts.MachineObservation
	for rows.Next() {
		var o contracts.MachineObservation
		var se, public string
		var raw, hardware []byte
		if err = rows.Scan(&o.SessionID, &o.AccountID, &se, &public, &raw, &o.Version, &hardware, &o.At); err != nil {
			rows.Close()
			return 0, err
		}
		var result attestation.VerificationResult
		if json.Unmarshal(raw, &result) == nil && result.Valid && result.PublicKey == se && result.EncryptionPublicKey == public {
			o.SEKey = se
		}
		var h struct {
			ChipName string  `json:"chip_name"`
			MemoryGB float64 `json:"memory_gb"`
		}
		_ = json.Unmarshal(hardware, &h)
		o.Chip = h.ChipName
		o.MemoryGB = h.MemoryGB
		o.Disconnected = true
		o.Source = "historical_registration"
		o.OSSource = "unknown"
		observations = append(observations, o)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, o := range observations {
		if _, err = s.ObserveMachine(ctx, o); err != nil {
			return 0, err
		}
	}
	return len(observations), nil
}
