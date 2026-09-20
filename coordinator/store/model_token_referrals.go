package store

// Promotion settlement already owns the consumer debit and provider credit.
// Record only its paid portion for referrals in that same lock/transaction.
// The reservation's terminal state fences retries and late attribution.
func promotionReferralRecord(r ModelTokenReservation, referrer string) consumerSettlementRecord {
	reward := int64(0)
	if referrer != "" {
		reward = r.ConsumerCostMicroUSD / (100 / ConsumerReferralPercent)
	}
	return consumerSettlementRecord{
		Input:    ConsumerChargeSettlement{AccountID: r.AccountID, JobID: "promotion:" + r.ID, ReservedMicroUSD: r.ReservedMicroUSD, CostMicroUSD: r.ConsumerCostMicroUSD, ReferralEnabled: true},
		Result:   ConsumerChargeResult{CollectedMicroUSD: r.ConsumerCostMicroUSD, ReferralRewardMicroUSD: reward, Applied: true},
		Referrer: referrer,
	}
}
