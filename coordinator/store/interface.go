// Package store provides storage backends for API keys, usage tracking,
// balance management, and payment records.
//
// Two implementations are provided:
//   - MemoryStore: In-memory storage for development and testing. Data is
//     lost on restart. Suitable for single-instance coordinators.
//   - PostgresStore: PostgreSQL-backed storage for production. Provides
//     persistence, atomic balance operations, and multi-instance support.
//
// The store also manages a double-entry ledger for consumer and provider
// balances. All monetary amounts are in micro-USD (1 USD = 1,000,000
// micro-USD), which maps 1:1 to pathUSD's 6-decimal on-chain representation
// on the Tempo blockchain.
//
// The Store interface is composed of per-domain fragments, each declared next
// to its record types in a <domain>.go file (apikeys.go, usage.go, ledger.go,
// etc.). The two implementations assert conformance to the whole composed
// interface via `var _ Store` in memory.go and postgres.go.
package store

// Store is the interface that all storage backends must implement. It is the
// union of the per-domain fragment interfaces below.
type Store interface {
	APIKeyStore
	UsageStore
	LedgerStore
	ReferralStore
	BillingSessionStore
	PricingStore
	ModelRegistryStore
	ReleaseStore
	UserStore
	StripeWithdrawalStore
	DeviceCodeStore
	InviteStore
	ProviderEarningsStore
	ProviderTokenStore
	ProviderStore
	ReputationStore
	LogReportStore
}
