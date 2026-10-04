package payouts_test

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (f *failingGlobalPayoutPersistence) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	f.recordCalls++
	if f.recordFailures > 0 {
		f.recordFailures--
		return errors.New("temporary rejection write failure")
	}
	return f.MemoryStore.RecordGlobalPayoutRejection(id, attempt, code)
}

func (f *failingGlobalPayoutPersistence) ApplyGlobalPayout(id string, result store.GlobalPayoutResult, now time.Time) error {
	f.refundCalls++
	if f.refundFailures > 0 {
		f.refundFailures--
		return errors.New("temporary refund transaction failure")
	}
	return f.MemoryStore.ApplyGlobalPayout(id, result, now)
}

func (f *failingGlobalPayoutPersistence) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	return f.MemoryStore.ClaimGlobalPayout(id, now.Add(f.claimOffset))
}
