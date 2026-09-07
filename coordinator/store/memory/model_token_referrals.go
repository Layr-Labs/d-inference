package memory

import (
	"errors"
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/store/consumersettlement"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) preparePromotionReferralLocked(r store.ModelTokenReservation, earning *store.ProviderEarning) (consumersettlement.Record, error) {
	referrer := ""
	if ref := s.referrersByCode[s.referrals[r.AccountID]]; ref != nil && ref.AccountID != r.AccountID {
		referrer = ref.AccountID
	}
	record := consumersettlement.PromotionRecord(r, referrer)
	if _, exists := s.consumerSettlements[record.Input.JobID]; exists {
		return record, errors.New("store: promotion referral settlement already exists")
	}
	reward := record.Result.ReferralRewardMicroUSD
	if reward > 0 {
		balance, withdrawable := s.balances[referrer], s.withdrawable[referrer]
		// The serving provider may also be the consumer's referrer.
		if earning != nil && earning.AccountID == referrer {
			if earning.AmountMicroUSD > math.MaxInt64-balance || earning.AmountMicroUSD > math.MaxInt64-withdrawable {
				return record, errors.New("store: promotion provider balance overflow")
			}
			balance += earning.AmountMicroUSD
			withdrawable += earning.AmountMicroUSD
		}
		if reward > math.MaxInt64-balance || reward > math.MaxInt64-withdrawable {
			return record, errors.New("store: promotion referral balance overflow")
		}
	}
	return record, nil
}

func (s *MemoryStore) recordPromotionReferralLocked(record consumersettlement.Record) {
	if reward := record.Result.ReferralRewardMicroUSD; reward > 0 {
		s.creditLocked(record.Referrer, reward, store.LedgerReferralReward, record.Input.JobID, s.now())
		s.withdrawable[record.Referrer] += reward
	}
	s.consumerSettlements[record.Input.JobID] = record
}
