package store

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
)

func GenerateRawKey() (string, error) {
	return contracts.GenerateRawKey()
}

func GenerateKeyID() (string, error) {
	return contracts.GenerateKeyID()
}

func LegacyAccountID(rawKey string) string {
	return contracts.LegacyAccountID(rawKey)
}

func KeyLabel(raw string) string {
	return contracts.KeyLabel(raw)
}

func NormalizeResetWindow(reset string) string {
	return contracts.NormalizeResetWindow(reset)
}

func KeySpendWindowStart(reset string, now time.Time) time.Time {
	return contracts.KeySpendWindowStart(reset, now)
}

func IsRewardLedgerType(t LedgerEntryType) bool {
	return contracts.IsRewardLedgerType(t)
}

func HashKey(key string) string {
	return contracts.HashKey(key)
}

func IsTransientWriteError(err error) bool {
	return postgres.IsTransientWriteError(err)
}
