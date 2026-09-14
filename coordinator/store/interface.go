package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

type (
	Unwrapper                     = contracts.Unwrapper
	Config                        = contracts.Config
	GlobalPayoutStore             = contracts.GlobalPayoutStore
	GlobalRecipient               = contracts.GlobalRecipient
	GlobalPayout                  = contracts.GlobalPayout
	GlobalPayoutRejection         = contracts.GlobalPayoutRejection
	GlobalPayoutResult            = contracts.GlobalPayoutResult
	HuggingFaceArtifact           = contracts.HuggingFaceArtifact
	Store                         = contracts.Store
	TelemetryEventRecord          = contracts.TelemetryEventRecord
	UsageRecord                   = contracts.UsageRecord
	InferenceRouteRecord          = contracts.InferenceRouteRecord
	InferenceRouteOutcome         = contracts.InferenceRouteOutcome
	InferenceRouteOutcomeUpdate   = contracts.InferenceRouteOutcomeUpdate
	RejectionRecord               = contracts.RejectionRecord
	UsageTotals                   = contracts.UsageTotals
	UsageBucket                   = contracts.UsageBucket
	UsageLocationBucket           = contracts.UsageLocationBucket
	UsageFlowBucket               = contracts.UsageFlowBucket
	LeaderboardMetric             = contracts.LeaderboardMetric
	LeaderboardRow                = contracts.LeaderboardRow
	NetworkTotalsRow              = contracts.NetworkTotalsRow
	LedgerEntryType               = contracts.LedgerEntryType
	LedgerEntry                   = contracts.LedgerEntry
	PaymentRecord                 = contracts.PaymentRecord
	Referrer                      = contracts.Referrer
	ReferralStats                 = contracts.ReferralStats
	ModelPrice                    = contracts.ModelPrice
	APIKey                        = contracts.APIKey
	APIKeyCreate                  = contracts.APIKeyCreate
	User                          = contracts.User
	StripeWithdrawal              = contracts.StripeWithdrawal
	SupportedModel                = contracts.SupportedModel
	ModelRegistryEntry            = contracts.ModelRegistryEntry
	ModelVersion                  = contracts.ModelVersion
	ModelVersionFile              = contracts.ModelVersionFile
	ModelRegistryRecord           = contracts.ModelRegistryRecord
	ModelAliasSourceKind          = contracts.ModelAliasSourceKind
	ModelAlias                    = contracts.ModelAlias
	ModelManifest                 = contracts.ModelManifest
	ManifestFile                  = contracts.ManifestFile
	PublishingAPIKey              = contracts.PublishingAPIKey
	Release                       = contracts.Release
	DeviceCode                    = contracts.DeviceCode
	ProviderToken                 = contracts.ProviderToken
	InviteCode                    = contracts.InviteCode
	InviteRedemption              = contracts.InviteRedemption
	ProviderEarning               = contracts.ProviderEarning
	ProviderFloorDraw             = contracts.ProviderFloorDraw
	ProviderEarningsSummary       = contracts.ProviderEarningsSummary
	AccountEarningsWindows        = contracts.AccountEarningsWindows
	ProviderPayout                = contracts.ProviderPayout
	BillingSession                = contracts.BillingSession
	ProviderRecord                = contracts.ProviderRecord
	ProviderSession               = contracts.ProviderSession
	ProviderLocation              = contracts.ProviderLocation
	LogReport                     = contracts.LogReport
	ReputationRecord              = contracts.ReputationRecord
	CodeAttestation               = contracts.CodeAttestation
	CodeAttestPushBudget          = contracts.CodeAttestPushBudget
	ProviderTrustReuse            = contracts.ProviderTrustReuse
	ProviderTrustReuseWriteResult = contracts.ProviderTrustReuseWriteResult
	VerificationTaskKind          = contracts.VerificationTaskKind
	VerificationTaskState         = contracts.VerificationTaskState
	VerificationPriority          = contracts.VerificationPriority
	VerificationOutcome           = contracts.VerificationOutcome
	VerificationJob               = contracts.VerificationJob
	APIKeyStore                   = contracts.APIKeyStore
	UsageStore                    = contracts.UsageStore
	TelemetryStore                = contracts.TelemetryStore
	LedgerStore                   = contracts.LedgerStore
	BillingStore                  = contracts.BillingStore
	ModelRegistryStore            = contracts.ModelRegistryStore
	ReleaseStore                  = contracts.ReleaseStore
	UserStore                     = contracts.UserStore
	DeviceAuthStore               = contracts.DeviceAuthStore
	InviteStore                   = contracts.InviteStore
	ProviderEarningsStore         = contracts.ProviderEarningsStore
	ProviderStore                 = contracts.ProviderStore
	RequestProfileRecord          = contracts.RequestProfileRecord
	FleetSnapshotRow              = contracts.FleetSnapshotRow
	RequestProfileFilter          = contracts.RequestProfileFilter
	RequestOutcomeRecord          = contracts.RequestOutcomeRecord
	RequestAttemptOutcome         = contracts.RequestAttemptOutcome
	RequestOutcomeStore           = contracts.RequestOutcomeStore
)

// Narrow domain contracts for subsystems that do not need a full backend.
type (
	ProviderRecordStore   = contracts.ProviderRecordStore
	ProviderSessionStore  = contracts.ProviderSessionStore
	ReputationStore       = contracts.ReputationStore
	CodeAttestationStore  = contracts.CodeAttestationStore
	TrustReuseStore       = contracts.TrustReuseStore
	VerificationStore     = contracts.VerificationStore
	LogReportStore        = contracts.LogReportStore
	ReferralStore         = contracts.ReferralStore
	BillingSessionStore   = contracts.BillingSessionStore
	ModelPriceStore       = contracts.ModelPriceStore
	StripeWithdrawalStore = contracts.StripeWithdrawalStore
)
