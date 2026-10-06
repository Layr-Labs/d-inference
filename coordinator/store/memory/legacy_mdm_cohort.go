package memory

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var _ store.LegacyMDMCohortStore = (*MemoryStore)(nil)

func (s *MemoryStore) FreezeLegacyMDMCohort(ctx context.Context) ([]store.LegacyMDMMachine, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s.legacyMDMCohortCutoff.IsZero() {
		cutoff := time.Now().UTC()
		members := map[store.LegacyMDMMachine]bool{}
		for _, p := range s.providerRecords {
			u := s.usersByAccountID[p.AccountID]
			if u == nil || !u.CreatedAt.Before(cutoff) || !p.RegisteredAt.Before(cutoff) || p.AccountID == "" || p.SEPublicKey == "" || p.SerialNumber == "" || s.machineInventory == nil {
				continue
			}
			alias := (store.MachineObservation{AccountID: p.AccountID, SEKey: p.SEPublicKey}).Aliases()[0]
			if s.machineInventory.Aliases[alias] == "" {
				continue
			}
			r := s.providerTrustReuse[p.SEPublicKey]
			historical := r.SEPubKey == p.SEPublicKey && r.Serial == p.SerialNumber && r.MDAUDID != "" && r.SIPEnabled && r.SecureBootFull && !r.HardwareProofVerifiedAt.IsZero() && r.HardwareProofVerifiedAt.Before(cutoff)
			// Hardware trust is granted only by MDM; hashless successes may have
			// no reuse row. Bind the retained valid attestation to this device.
			var a map[string]any
			hardware := p.TrustLevel == "hardware" && p.Attested && json.Unmarshal(p.AttestationResult, &a) == nil && a["Valid"] == true && a["SecureEnclaveAvailable"] == true && a["SIPEnabled"] == true && a["SecureBootEnabled"] == true && a["PublicKey"] == p.SEPublicKey && a["SerialNumber"] == p.SerialNumber
			if historical || hardware {
				members[store.LegacyMDMMachine{AccountID: p.AccountID, SEPublicKey: p.SEPublicKey, SerialNumber: p.SerialNumber}] = true
			}
		}
		serials := map[[2]string]string{}
		for m := range members {
			identity := [2]string{m.AccountID, m.SEPublicKey}
			if serial, exists := serials[identity]; exists && serial != m.SerialNumber {
				serials[identity] = ""
			} else if !exists {
				serials[identity] = m.SerialNumber
			}
		}
		for m := range members {
			// Conflicting successful serial bindings are not eligibility evidence.
			if serials[[2]string{m.AccountID, m.SEPublicKey}] != "" {
				s.legacyMDMCohort = append(s.legacyMDMCohort, m)
			}
		}
		sort.Slice(s.legacyMDMCohort, func(i, j int) bool {
			a, b := s.legacyMDMCohort[i], s.legacyMDMCohort[j]
			if a.AccountID != b.AccountID {
				return a.AccountID < b.AccountID
			}
			if a.SEPublicKey != b.SEPublicKey {
				return a.SEPublicKey < b.SEPublicKey
			}
			return a.SerialNumber < b.SerialNumber
		})
		s.legacyMDMCohortCutoff = cutoff
	}
	return append([]store.LegacyMDMMachine{}, s.legacyMDMCohort...), nil
}
