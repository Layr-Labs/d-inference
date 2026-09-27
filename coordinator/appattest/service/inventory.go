package service

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type machineInventorySession struct {
	readyOnce   sync.Once
	dropped     func() uint64
	mu          sync.Mutex
	identity    store.MachineIdentity
	ready       chan struct{}
	s           *Service
	p           *registry.Provider
	store       store.MachineInventoryStore
	observation store.MachineObservation
}

func (s *Service) startMachineInventory(ctx context.Context, p *registry.Provider, r *protocol.RegisterMessage, account string) *machineInventorySession {
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
	x := &machineInventorySession{s: s, p: p, store: st, ready: make(chan struct{}), observation: store.MachineObservation{
		OSSource: "registration_report", OSObservedAt: time.Now().UTC(), Source: "live_registration", SessionID: p.ID, AccountID: account, OSVersion: version, OSMajor: reportedOSMajor(version), Version: boundedShadowLabel(r.Version),
		Chip: boundedShadowLabel(r.Hardware.ChipName), MemoryGB: float64(r.Hardware.MemoryGB), Protocol: r.AppAttestProtocol, ShadowEnabled: s.config.Enabled,
	}}
	ctx, cancel := context.WithCancel(ctx)
	stop := func() bool { return false }
	if s.lifetime != nil {
		stop = context.AfterFunc(s.lifetime, cancel)
	}
	saferun.Go(s.logger, "machineInventory", func() {
		defer cancel()
		defer stop()
		x.capture(false)
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				x.capture(true)
				return
			case <-ticker.C:
				x.capture(false)
			}
		}
	})
	return x
}

func (x *machineInventorySession) snapshot() store.MachineIdentity {
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.identity
}

func (x *machineInventorySession) capture(disconnected bool) {
	x.mu.Lock()
	o := x.observation
	if x.dropped != nil {
		o.ShadowDropped = x.dropped()
	}
	x.mu.Unlock()
	o.At = time.Now().UTC()
	o.Disconnected = disconnected
	x.p.Mu().Lock()
	o.LegacyTrust = string(x.p.TrustLevel)
	o.LegacyCode = x.p.CodeAttested
	o.LegacyMDA = x.p.MDAVerified
	if a := x.p.AttestationResult; a != nil && a.Valid && a.EncryptionPublicKey == x.p.PublicKey {
		o.SEKey = a.PublicKey
		// Serial-only MDA association is insufficient here: require Apple's
		// proof to be bound to this SE key before coalescing physical machines.
		if m := x.p.MDAResult; x.p.TrustLevel == registry.TrustHardware && x.p.MDAVerified && x.p.SEKeyBound && m != nil && m.Valid {
			o.VerifiedSerial = m.DeviceSerial
		}
	}
	x.p.Mu().Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if x.s.inventorySlots != nil {
		select {
		case x.s.inventorySlots <- struct{}{}:
			defer func() { <-x.s.inventorySlots }()
		case <-ctx.Done():
			x.s.ddIncr("app_attest.inventory.failed", []string{"reason:busy"})
			return
		}
	}
	id, err := x.store.ObserveMachine(ctx, o)
	if err != nil {
		x.s.ddIncr("app_attest.inventory.failed", []string{"reason:storage_error"})
		return
	}
	x.mu.Lock()
	x.identity = id
	x.mu.Unlock()
	x.readyOnce.Do(func() {
		if x.ready != nil {
			close(x.ready)
		}
	})
	x.s.ddIncr("app_attest.inventory.recorded", nil)
}

func reportedOSMajor(version string) int {
	version = strings.TrimPrefix(version, "Version ")
	first := strings.SplitN(version, ".", 2)[0]
	n, err := strconv.Atoi(first)
	if err != nil || n < 10 || n > 99 {
		return 0
	}
	return n
}
