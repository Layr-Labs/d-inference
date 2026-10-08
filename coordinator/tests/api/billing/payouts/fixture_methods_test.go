package payouts_test

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (f *failingGlobalPayoutPersistence) RecordGlobalPayoutRejection(id string, attempt int, code string, leaseUntil time.Time) error {
	f.recordCalls++
	if f.recordFailures > 0 {
		f.recordFailures--
		return errors.New("temporary rejection write failure")
	}
	return f.MemoryStore.RecordGlobalPayoutRejection(id, attempt, code, leaseUntil)
}

func (f *failingGlobalPayoutPersistence) ApplyGlobalPayout(id string, result store.GlobalPayoutResult, now time.Time) error {
	f.refundCalls++
	if f.refundFailures > 0 {
		f.refundFailures--
		return errors.New("temporary refund transaction failure")
	}
	return f.MemoryStore.ApplyGlobalPayout(id, result, now)
}

func (f *failingGlobalPayoutPersistence) ClaimGlobalPayout(id string, now time.Time) (*store.GlobalPayout, error) {
	return f.MemoryStore.ClaimGlobalPayout(id, now.Add(f.claimOffset))
}
