package exchange

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

// exchangeManager owns one-shot command and response bindings, independently of HTTP.
type Manager struct {
	waitMu         sync.Mutex
	secInfoWaiters map[string]securityInfoWaiter
	attestWaiters  map[string]deviceAttestationWaiter
	outstandingMu  sync.Mutex
	outstanding    map[string]outstandingCommand
}

func New() *Manager {
	return &Manager{
		secInfoWaiters: make(map[string]securityInfoWaiter),
		attestWaiters:  make(map[string]deviceAttestationWaiter),
		outstanding:    make(map[string]outstandingCommand),
	}
}

// ErrWaiterAlreadyRegistered is returned when command ownership for a UDID is
// already held by another live attempt. Overwriting a waiter could route a
// response to the wrong verification job.
var ErrWaiterAlreadyRegistered = errors.New("mdm waiter already registered")

// DeviceAttestationResponse contains the DER-encoded certificate chain
// from Apple's DevicePropertiesAttestation response.
type DeviceAttestationResponse struct {
	UDID      string
	CertChain [][]byte // DER-encoded certificates, leaf first
}

// outstandingCommand records a command UUID the coordinator issued, so the
// webhook can verify an inbound response was solicited.
type outstandingCommand struct {
	udid     string
	issuedAt time.Time
}

type securityInfoWaiter struct {
	commandUUID string
	ch          chan *SecurityInfoResponse
	early       map[string]*SecurityInfoResponse
}

const maxEarlySecurityInfoResponses = 4

type deviceAttestationWaiter struct {
	commandUUID string
	ch          chan *DeviceAttestationResponse
}

// outstandingCommandTTL bounds how long an issued command UUID stays valid for
// matching a webhook response. It must comfortably exceed the worst-case APN /
// Power Nap delivery delay (a sleeping Mac wakes on roughly a ~15-minute Power
// Nap cadence — see the late-SecurityInfo callback in cmd/coordinator/main.go),
// otherwise the UUID expires before a genuine SecurityInfo response arrives,
// consumeCommand drops it as stale, and the self_signed→hardware recovery path
// never fires. 30 minutes covers that delay while still bounding the forge
// window if a (random, localhost-only) UUID ever leaked.
const outstandingCommandTTL = 30 * time.Minute

// trackCommand records an issued command UUID so the webhook can confirm a
// later response was solicited. Prunes expired entries opportunistically.
func (c *Manager) TrackCommand(commandUUID, udid string, now time.Time) {
	if commandUUID == "" {
		return
	}
	c.outstandingMu.Lock()
	defer c.outstandingMu.Unlock()
	for id, cmd := range c.outstanding {
		if now.Sub(cmd.issuedAt) > outstandingCommandTTL {
			delete(c.outstanding, id)
		}
	}
	c.outstanding[commandUUID] = outstandingCommand{udid: udid, issuedAt: now}
}

// consumeCommand checks whether commandUUID corresponds to a command the
// coordinator issued (and has not yet expired), removing it (one-shot). It
// returns the UDID the command was sent to and whether the match succeeded.
func (c *Manager) ConsumeCommand(commandUUID string, now time.Time) (string, bool) {
	if commandUUID == "" {
		return "", false
	}
	c.outstandingMu.Lock()
	defer c.outstandingMu.Unlock()
	cmd, ok := c.outstanding[commandUUID]
	if !ok {
		return "", false
	}
	delete(c.outstanding, commandUUID)
	if now.Sub(cmd.issuedAt) > outstandingCommandTTL {
		return "", false
	}
	return cmd.udid, true
}

// SecurityInfoResponse parsed from the MDM SecurityInfo command response.
type SecurityInfoResponse struct {
	UDID                             string
	SystemIntegrityProtectionEnabled bool
	SecureBootLevel                  string // "full", "reduced", "permissive"
	AuthenticatedRootVolumeEnabled   bool
	FirewallEnabled                  bool
	FileVaultEnabled                 bool
	IsRecoveryLockEnabled            bool
	RemoteDesktopEnabled             bool
}

func (c *Manager) RegisterDeviceAttestationWaiter(
	udid string,
) (<-chan *DeviceAttestationResponse, func(string) bool, func(), error) {
	ch := make(chan *DeviceAttestationResponse, 1)
	c.waitMu.Lock()
	if _, exists := c.attestWaiters[udid]; exists {
		c.waitMu.Unlock()
		return nil, nil, nil, fmt.Errorf("%w: device attestation", ErrWaiterAlreadyRegistered)
	}
	c.attestWaiters[udid] = deviceAttestationWaiter{ch: ch}
	c.waitMu.Unlock()
	bind := func(commandUUID string) bool {
		c.waitMu.Lock()
		defer c.waitMu.Unlock()
		cur, ok := c.attestWaiters[udid]
		if !ok || cur.ch != ch || cur.commandUUID != "" || commandUUID == "" {
			return false
		}
		cur.commandUUID = commandUUID
		c.attestWaiters[udid] = cur
		return true
	}
	release := func() {
		c.waitMu.Lock()
		if cur, ok := c.attestWaiters[udid]; ok && cur.ch == ch {
			delete(c.attestWaiters, udid)
		}
		c.waitMu.Unlock()
	}
	return ch, bind, release, nil
}

func AwaitDeviceAttestation(ctx context.Context, ch <-chan *DeviceAttestationResponse, timeout time.Duration) (*DeviceAttestationResponse, error) {
	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("device attestation wait cancelled: %w", ctx.Err())
	case <-time.After(timeout):
		return nil, errors.New("timeout waiting for DevicePropertiesAttestation")
	}
}

func (c *Manager) BufferEarlySecurityInfo(
	udid, commandUUID string,
	resp *SecurityInfoResponse,
) bool {
	if udid == "" || commandUUID == "" || resp == nil {
		return false
	}
	c.waitMu.Lock()
	defer c.waitMu.Unlock()
	waiter, ok := c.secInfoWaiters[udid]
	if !ok || waiter.commandUUID != "" {
		return false
	}
	if waiter.early == nil {
		waiter.early = make(map[string]*SecurityInfoResponse)
	}
	if _, exists := waiter.early[commandUUID]; !exists &&
		len(waiter.early) >= maxEarlySecurityInfoResponses {
		return false
	}
	waiter.early[commandUUID] = resp
	c.secInfoWaiters[udid] = waiter
	return true
}

// registerSecurityInfoWaiter installs exclusive one-shot command ownership for
// a UDID. It rejects overlap rather than replacing a live attempt's channel.
func (c *Manager) RegisterSecurityInfoWaiter(
	udid string,
) (<-chan *SecurityInfoResponse, func(string) bool, func(), error) {
	ch := make(chan *SecurityInfoResponse, 1)
	c.waitMu.Lock()
	if _, exists := c.secInfoWaiters[udid]; exists {
		c.waitMu.Unlock()
		return nil, nil, nil, fmt.Errorf("%w: SecurityInfo", ErrWaiterAlreadyRegistered)
	}
	c.secInfoWaiters[udid] = securityInfoWaiter{ch: ch}
	c.waitMu.Unlock()
	bind := func(commandUUID string) bool {
		c.waitMu.Lock()
		cur, ok := c.secInfoWaiters[udid]
		if !ok || cur.ch != ch || cur.commandUUID != "" || commandUUID == "" {
			c.waitMu.Unlock()
			return false
		}
		cur.commandUUID = commandUUID
		early := cur.early[commandUUID]
		if early != nil {
			delete(c.secInfoWaiters, udid)
		} else {
			c.secInfoWaiters[udid] = cur
		}
		c.waitMu.Unlock()
		if early != nil {
			c.ConsumeCommand(commandUUID, time.Now())
			ch <- early
		}
		return true
	}
	release := func() {
		c.waitMu.Lock()
		if cur, ok := c.secInfoWaiters[udid]; ok && cur.ch == ch {
			delete(c.secInfoWaiters, udid)
		}
		c.waitMu.Unlock()
	}
	return ch, bind, release, nil
}

// awaitSecurityInfo blocks on a previously-registered waiter channel until the
// response arrives, ctx is cancelled, or the timeout elapses.
func AwaitSecurityInfo(ctx context.Context, ch <-chan *SecurityInfoResponse, timeout time.Duration) (*SecurityInfoResponse, error) {
	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("SecurityInfo wait cancelled: %w", ctx.Err())
	case <-time.After(timeout):
		return nil, errors.New("timeout waiting for SecurityInfo")
	}
}
