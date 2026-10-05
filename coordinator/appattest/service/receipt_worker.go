package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/receipt"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Receipt renewal is independent of new exchanges and the DCDevice service.
func (s *Service) startAppAttestReceiptWorker(ctx context.Context) {
	st, _ := store.As[store.AppAttestReceiptStore](s.store)
	worker := receipt.New(receipt.Config{KeyPath: s.config.ReceiptKeyPath, KeyID: s.config.ReceiptKeyID}, receipt.Dependencies{
		Store: st, Now: s.receiptNow, Client: s.receiptClient, Increment: s.ddIncr,
	})
	if worker == nil {
		s.ddGauge("app_attest.receipt.configured", 0, nil)
		return
	}
	s.ddGauge("app_attest.receipt.configured", 1, nil)
	saferun.Go(s.logger, "appAttestReceiptRenewal", func() {
		// One request per second; durable leases fence competing replicas.
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		worker.Run(ctx, ticker.C)
	})
}
