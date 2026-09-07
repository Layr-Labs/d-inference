package api

import (
	"errors"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type lostConsumerSettlementResultStore struct {
	store.Store
	remaining atomic.Int32
	started   chan struct{}
	release   chan struct{}
}

func (s *lostConsumerSettlementResultStore) FinalizeConsumerCharge(in store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error) {
	result, err := s.Store.FinalizeConsumerCharge(in)
	if err != nil {
		return result, err
	}
	if result.Applied && s.started != nil {
		close(s.started)
		<-s.release
	}
	if s.remaining.Add(-1) >= 0 {
		return store.ConsumerChargeResult{}, errors.New("commit applied but response lost")
	}
	return result, nil
}

func TestConsumerSettlementUnknownCommitFencesConcurrentRefund(t *testing.T) {
	for _, service := range []bool{false, true} {
		t.Run(map[bool]string{false: "ledger", true: "service_hold"}[service], func(t *testing.T) {
			srv, st, _ := billingTestServer(t)
			consumer, referrer := "unknown-consumer", "unknown-referrer"
			if err := st.Credit(consumer, 1000, store.LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			if err := st.CreateReferrer(referrer, "UNKNOWN"); err != nil {
				t.Fatal(err)
			}
			if err := st.RecordReferral("UNKNOWN", consumer); err != nil {
				t.Fatal(err)
			}
			pr := &registry.PendingRequest{ConsumerKey: consumer, RequestID: "unknown-job", ReservedMicroUSD: 600, ServiceReservation: service}
			if service {
				srv.serviceReservations = newServiceReservationManager(st, true)
				if err := srv.serviceReservations.Reserve(consumer, 600); err != nil {
					t.Fatal(err)
				}
			} else if err := st.Debit(consumer, 600, store.LedgerCharge, "reserve"); err != nil {
				t.Fatal(err)
			}
			wrapped := &lostConsumerSettlementResultStore{Store: st, started: make(chan struct{}), release: make(chan struct{})}
			wrapped.remaining.Store(3)
			srv.store = wrapped
			done := make(chan bool, 1)
			go func() { ok, _, _ := srv.settleCompletedConsumer(pr, 400, nil, false); done <- ok }()
			<-wrapped.started // financial commit completed, reservation lock still held
			refunded := make(chan bool, 1)
			go func() { refunded <- srv.refundReservedBalance(pr, "timeout-sweep") }()
			close(wrapped.release)
			if <-done {
				t.Fatal("unknown settlement reported successful")
			}
			if <-refunded {
				t.Fatal("generic refund won after an unknown committed settlement")
			}
			if !pr.IsReservationFinalized() {
				t.Fatal("unknown settlement left refund gate open")
			}
			if st.GetBalance(consumer) != 600 || st.GetBalance(referrer) != 20 {
				t.Fatalf("consumer=%d referrer=%d", st.GetBalance(consumer), st.GetBalance(referrer))
			}
			if service {
				srv.serviceReservations.mu.Lock()
				outstanding := srv.serviceReservations.outstanding[consumer]
				srv.serviceReservations.mu.Unlock()
				if outstanding != 0 {
					t.Fatalf("service hold leaked: %d", outstanding)
				}
			}
		})
	}
}

func TestConsumerSettlementRecoversLostCommitResult(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	consumer, referrer := "retry-consumer", "retry-referrer"
	if err := st.Credit(consumer, 1000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateReferrer(referrer, "RETRY"); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordReferral("RETRY", consumer); err != nil {
		t.Fatal(err)
	}
	wrapped := &lostConsumerSettlementResultStore{Store: st}
	wrapped.remaining.Store(1)
	srv.store = wrapped
	pr := &registry.PendingRequest{ConsumerKey: consumer, RequestID: "retry-job"}
	ok, cost, payout := srv.settleCompletedConsumer(pr, 400, nil, false)
	if !ok || cost != 400 || payout != 400 {
		t.Fatalf("ok=%v cost=%d payout=%d", ok, cost, payout)
	}
	if st.GetBalance(consumer) != 600 || st.GetBalance(referrer) != 20 || len(st.LedgerHistory(referrer)) != 1 {
		t.Fatal("retry repeated financial side effects")
	}
}

func TestConsumerSettlementUncollectedAdminRequestDoesNotEarnReferral(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	if err := st.CreateReferrer("admin-referrer", "ADMIN"); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordReferral("ADMIN", "unfunded-admin"); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{ConsumerKey: "unfunded-admin", RequestID: "admin-job"}
	ok, cost, payout := srv.settleCompletedConsumer(pr, 400, nil, false)
	if !ok || cost != 400 || payout != 400 {
		t.Fatalf("legacy platform-covered payout changed: ok=%v cost=%d payout=%d", ok, cost, payout)
	}
	if st.GetBalance("admin-referrer") != 0 {
		t.Fatal("uncollected admin request earned reward")
	}
}
