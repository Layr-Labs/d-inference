package cachetracker

import "github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"

var donationOutcomeBuckets = cachepolicy.DonationOutcomes()

type ReceiptLifecycle struct {
	SSDLookups, SSDHits, SSDMisses, SSDDonations uint64
	DonationOutcomes                             map[string]uint64
}

func (t *Tracker[P]) RecordDonationOutcomes(deltas map[string]uint64) {
	for outcome, delta := range deltas {
		if delta == 0 || !cachepolicy.Contains(donationOutcomeBuckets, outcome) {
			continue
		}
		current := t.donationOutcomes[outcome]
		if ^uint64(0)-current < delta {
			t.donationOutcomes[outcome] = ^uint64(0)
		} else {
			t.donationOutcomes[outcome] = current + delta
		}
	}
}

func (t *Tracker[P]) ReceiptLifecycle() ReceiptLifecycle {
	outcomes := make(map[string]uint64, len(donationOutcomeBuckets))
	for _, outcome := range donationOutcomeBuckets {
		outcomes[outcome] = 0
	}
	for outcome, count := range t.donationOutcomes {
		outcomes[outcome] = count
	}
	return ReceiptLifecycle{SSDLookups: t.ssdLookups, SSDHits: t.ssdHits, SSDMisses: t.ssdMisses, SSDDonations: t.ssdDonations, DonationOutcomes: outcomes}
}
