package store

import (
	"errors"
	"fmt"
)

func validateInferenceSettlement(settlement *InferenceSettlement) error {
	if settlement == nil {
		return errors.New("inference settlement is required")
	}
	if settlement.ReservationID == "" || settlement.RequestID == "" ||
		settlement.ConsumerAccountID == "" {
		return errors.New("inference settlement identities are required")
	}
	if settlement.ReservedMicroUSD < 0 ||
		settlement.ReservedWithdrawableMicroUSD < 0 ||
		settlement.ReservedWithdrawableMicroUSD > settlement.ReservedMicroUSD ||
		settlement.CostMicroUSD < 0 ||
		settlement.CostMicroUSD > settlement.ReservedMicroUSD ||
		settlement.PlatformFeeMicroUSD < 0 ||
		settlement.ReferralRewardMicroUSD < 0 {
		return ErrFinancialOperationConflict
	}
	providerPayout := int64(0)
	if settlement.ProviderEarning != nil {
		if settlement.ProviderEarning.JobID != settlement.RequestID ||
			settlement.ProviderEarning.AccountID == "" ||
			settlement.ProviderEarning.AmountMicroUSD < 0 {
			return ErrFinancialOperationConflict
		}
		providerPayout = settlement.ProviderEarning.AmountMicroUSD
	}
	if settlement.ReferralRewardMicroUSD > 0 && settlement.ReferrerAccountID == "" {
		return ErrFinancialOperationConflict
	}
	if providerPayout > settlement.CostMicroUSD ||
		settlement.PlatformFeeMicroUSD > settlement.CostMicroUSD-providerPayout ||
		settlement.ReferralRewardMicroUSD >
			settlement.CostMicroUSD-providerPayout-settlement.PlatformFeeMicroUSD {
		return fmt.Errorf("%w: beneficiary credits exceed collected cost", ErrFinancialOperationConflict)
	}
	if settlement.ReferralRewardMicroUSD !=
		settlement.CostMicroUSD-providerPayout-settlement.PlatformFeeMicroUSD {
		return fmt.Errorf("%w: beneficiary credits do not conserve collected cost", ErrFinancialOperationConflict)
	}
	if settlement.Usage != nil {
		if settlement.Usage.RequestID != settlement.RequestID ||
			settlement.Usage.CostMicroUSD != settlement.CostMicroUSD {
			return ErrFinancialOperationConflict
		}
	}
	return nil
}

func equivalentInferenceSettlement(left, right *InferenceSettlement) bool {
	if left == nil || right == nil {
		return left == right
	}
	if left.ReservationID != right.ReservationID ||
		left.RequestID != right.RequestID ||
		left.ConsumerAccountID != right.ConsumerAccountID ||
		left.ReservedMicroUSD != right.ReservedMicroUSD ||
		left.ReservedWithdrawableMicroUSD != right.ReservedWithdrawableMicroUSD ||
		left.ReservationPreDebited != right.ReservationPreDebited ||
		left.CostMicroUSD != right.CostMicroUSD ||
		left.PlatformFeeMicroUSD != right.PlatformFeeMicroUSD ||
		left.ReferrerAccountID != right.ReferrerAccountID ||
		left.ReferralRewardMicroUSD != right.ReferralRewardMicroUSD {
		return false
	}
	return equivalentProviderEarning(left.ProviderEarning, right.ProviderEarning) &&
		equivalentUsage(left.Usage, right.Usage)
}

func equivalentProviderEarning(left, right *ProviderEarning) bool {
	if left == nil || right == nil {
		return left == right
	}
	return left.AccountID == right.AccountID &&
		left.ProviderID == right.ProviderID &&
		left.ProviderKey == right.ProviderKey &&
		left.JobID == right.JobID &&
		left.Model == right.Model &&
		left.AmountMicroUSD == right.AmountMicroUSD &&
		left.PromptTokens == right.PromptTokens &&
		left.CompletionTokens == right.CompletionTokens
}

func equivalentUsage(left, right *UsageRecord) bool {
	if left == nil || right == nil {
		return left == right
	}
	return left.ProviderID == right.ProviderID &&
		left.ConsumerKey == right.ConsumerKey &&
		left.KeyID == right.KeyID &&
		left.Model == right.Model &&
		left.PublicModel == right.PublicModel &&
		left.PromptTokens == right.PromptTokens &&
		left.CompletionTokens == right.CompletionTokens &&
		left.RequestID == right.RequestID &&
		left.CostMicroUSD == right.CostMicroUSD
}
