package api

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type serviceReservationManager struct {
	store   store.Store
	enabled bool

	mu          sync.Mutex
	outstanding map[string]int64
}

func newServiceReservationManager(st store.Store, enabled bool) *serviceReservationManager {
	return &serviceReservationManager{store: st, enabled: enabled, outstanding: make(map[string]int64)}
}

func (m *serviceReservationManager) Enabled() bool {
	return m != nil && m.enabled
}

func (m *serviceReservationManager) Reserve(accountID string, amount int64) error {
	if m == nil || !m.enabled || amount <= 0 {
		return nil
	}
	balance := m.store.GetBalance(accountID)

	m.mu.Lock()
	defer m.mu.Unlock()
	if balance-m.outstanding[accountID] < amount {
		return store.ErrInsufficientBalance
	}
	m.outstanding[accountID] += amount
	return nil
}

func (m *serviceReservationManager) Release(accountID string, amount int64) {
	if m == nil || !m.enabled || amount <= 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	current := m.outstanding[accountID]
	if amount >= current {
		delete(m.outstanding, accountID)
		return
	}
	m.outstanding[accountID] = current - amount
}

func reservationMetricMode(service bool) string {
	if service {
		return "service_hold"
	}
	return "ledger"
}

func (s *Server) useServiceReservation(accountID string) bool {
	return s.serviceReservations != nil && s.serviceReservations.Enabled() && s.isServiceConsumer(accountID)
}

func (s *Server) reserveInitialBalance(accountID, model string, amount int64) (bool, error) {
	serviceMode := s.useServiceReservation(accountID)
	start := time.Now()
	if serviceMode {
		if err := s.serviceReservations.Reserve(accountID, amount); err != nil {
			s.ddIncr("billing.reservations", []string{"model:" + model, "mode:service_hold", "outcome:rejected"})
			return true, err
		}
		s.ddIncr("billing.reservations", []string{"model:" + model, "mode:service_hold", "outcome:reserved"})
		s.ddHistogram("billing.reserved_micro_usd", float64(amount), []string{"model:" + model, "mode:service_hold"})
		return true, nil
	}
	if err := s.ledger.Charge(accountID, amount, "reserve:"+accountID); err != nil {
		s.ddIncr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:rejected"})
		return false, err
	}
	s.ddIncr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:reserved"})
	s.ddHistogram("billing.reserved_micro_usd", float64(amount), []string{"model:" + model, "mode:ledger"})
	s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	return false, nil
}

func (s *Server) releaseInitialReservation(accountID, model string, amount int64, serviceMode bool) {
	if amount <= 0 {
		return
	}
	tags := []string{"model:" + model, "mode:" + reservationMetricMode(serviceMode)}
	if serviceMode {
		s.serviceReservations.Release(accountID, amount)
		s.ddIncr("billing.reservation_releases", append(tags, "reason:early"))
		return
	}
	start := time.Now()
	_ = s.store.Credit(accountID, amount, store.LedgerRefund, "reservation_refund")
	s.ddIncr("billing.reservation_refunds", tags)
	s.ddIncr("billing.reservation_releases", append(tags, "reason:early"))
	s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
}

func (s *Server) releaseServiceReservation(pr *registry.PendingRequest, reason string) {
	if pr == nil || !pr.ServiceReservation {
		return
	}
	s.serviceReservations.Release(pr.ConsumerKey, pr.ReservedMicroUSD)
	if reason == "" {
		reason = "unknown"
	}
	s.ddIncr("billing.reservation_releases", []string{"model:" + pr.Model, "mode:service_hold", "reason:" + reason})
}
