package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Service) startMachineInventory(ctx context.Context, p *registry.Provider, r *protocol.RegisterMessage, account string) *inventory.Session {
	st, ok := store.As[store.MachineInventoryStore](s.store)
	if !ok {
		s.ddIncr("app_attest.inventory.failed", []string{"reason:store_unavailable"})
		return nil
	}
	var report struct {
		Attestation struct {
			OSVersion string `json:"osVersion"`
		} `json:"attestation"`
	}
	_ = json.Unmarshal(r.Attestation, &report)
	version := boundedShadowLabel(report.Attestation.OSVersion)
	x := inventory.NewSession(inventory.SessionDependencies{Store: st, Provider: p, Slots: s.inventorySlots, Count: s.ddIncr}, store.MachineObservation{
		OSSource: "registration_report", OSObservedAt: time.Now().UTC(), Source: "live_registration", SessionID: p.ID, AccountID: account, OSVersion: version, OSMajor: reportedOSMajor(version), Version: boundedShadowLabel(r.Version),
		Chip: boundedShadowLabel(r.Hardware.ChipName), MemoryGB: float64(r.Hardware.MemoryGB), Protocol: r.AppAttestProtocol, ShadowEnabled: s.config.Enabled,
	})
	ctx, cancel := context.WithCancel(ctx)
	stop := func() bool { return false }
	if s.lifetime != nil {
		stop = context.AfterFunc(s.lifetime, cancel)
	}
	saferun.Go(s.logger, "machineInventory", func() {
		defer cancel()
		defer stop()
		x.Capture(false)
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				x.Capture(true)
				return
			case <-ticker.C:
				x.Capture(false)
			}
		}
	})
	return x
}

func reportedOSMajor(version string) int {
	return inventory.ReportedOSMajor(version)
}
