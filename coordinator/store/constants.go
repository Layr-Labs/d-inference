package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

const (
	KeyPrefix                          = contracts.KeyPrefix
	GlobalPayoutManualReview           = contracts.GlobalPayoutManualReview
	LeaderboardEarnings                = contracts.LeaderboardEarnings
	LeaderboardTokens                  = contracts.LeaderboardTokens
	LeaderboardJobs                    = contracts.LeaderboardJobs
	LedgerDeposit                      = contracts.LedgerDeposit
	LedgerCharge                       = contracts.LedgerCharge
	LedgerPayout                       = contracts.LedgerPayout
	LedgerPlatformFee                  = contracts.LedgerPlatformFee
	LedgerWithdrawal                   = contracts.LedgerWithdrawal
	LedgerReferralReward               = contracts.LedgerReferralReward
	LedgerStripeDeposit                = contracts.LedgerStripeDeposit
	LedgerStripePayout                 = contracts.LedgerStripePayout
	LedgerInviteCredit                 = contracts.LedgerInviteCredit
	LedgerRefund                       = contracts.LedgerRefund
	LedgerAdminCredit                  = contracts.LedgerAdminCredit
	LedgerAdminReward                  = contracts.LedgerAdminReward
	LedgerMigration                    = contracts.LedgerMigration
	LedgerFloorDraw                    = contracts.LedgerFloorDraw
	KeyResetNone                       = contracts.KeyResetNone
	KeyResetDaily                      = contracts.KeyResetDaily
	KeyResetWeekly                     = contracts.KeyResetWeekly
	KeyResetMonthly                    = contracts.KeyResetMonthly
	RoleService                        = contracts.RoleService
	MaxStripeWithdrawalsByStatusLimit  = contracts.MaxStripeWithdrawalsByStatusLimit
	ModelAliasSourceAlias              = contracts.ModelAliasSourceAlias
	ModelAliasSourceConcrete           = contracts.ModelAliasSourceConcrete
	CodeAttestPushBudgetMaxTokenRows   = contracts.CodeAttestPushBudgetMaxTokenRows
	VerificationTaskSecurityInfo       = contracts.VerificationTaskSecurityInfo
	VerificationTaskMDA                = contracts.VerificationTaskMDA
	VerificationStateWaitingChallenge  = contracts.VerificationStateWaitingChallenge
	VerificationStatePending           = contracts.VerificationStatePending
	VerificationStateRunning           = contracts.VerificationStateRunning
	VerificationStateBackoff           = contracts.VerificationStateBackoff
	VerificationStateCompleted         = contracts.VerificationStateCompleted
	VerificationPriorityFirstOrExpired = contracts.VerificationPriorityFirstOrExpired
	VerificationPriorityRecovery       = contracts.VerificationPriorityRecovery
	VerificationPriorityRefresh        = contracts.VerificationPriorityRefresh
	VerificationOutcomeNone            = contracts.VerificationOutcomeNone
	VerificationOutcomeSuccess         = contracts.VerificationOutcomeSuccess
	VerificationOutcomeReused          = contracts.VerificationOutcomeReused
	VerificationOutcomeTransient       = contracts.VerificationOutcomeTransient
	VerificationOutcomeTimeout         = contracts.VerificationOutcomeTimeout
	VerificationOutcomePostureMismatch = contracts.VerificationOutcomePostureMismatch
	VerificationOutcomeInvalid         = contracts.VerificationOutcomeInvalid
	VerificationOutcomeCancelled       = contracts.VerificationOutcomeCancelled
	VerificationOutcomeError           = contracts.VerificationOutcomeError
	DefaultPruneMaxEntries             = memory.DefaultPruneMaxEntries
	RequestOutcomeSchemaVersion        = contracts.RequestOutcomeSchemaVersion
	MaxRequestOutcomeAttempts          = contracts.MaxRequestOutcomeAttempts
)
