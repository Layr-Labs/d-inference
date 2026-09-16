package mdm

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// DeviceAttestationResponse contains the DER-encoded certificate chain
// from Apple's DevicePropertiesAttestation response.
type DeviceAttestationResponse struct {
	UDID      string
	CertChain [][]byte // DER-encoded certificates, leaf first
}

type deviceAttestationWaiter struct {
	commandUUID string
	ch          chan *DeviceAttestationResponse
}

// RequestDeviceAttestation installs the waiter and exact command observer before
// the raw command becomes visible to a device.
func (c *Client) RequestDeviceAttestation(
	ctx context.Context,
	udid, nonce string,
	timeout time.Duration,
	observeCommand func(udid, commandUUID string),
) (*DeviceAttestationResponse, error) {
	ch, bind, release, err := c.registerDeviceAttestationWaiter(udid)
	if err != nil {
		return nil, err
	}
	defer release()
	bindObservedCommand := func(commandUUID string) bool {
		if !bind(commandUUID) {
			return false
		}
		if observeCommand != nil {
			observeCommand(udid, commandUUID)
		}
		return true
	}
	if _, err := c.sendDeviceAttestationWithNonce(
		ctx, udid, nonce, bindObservedCommand,
	); err != nil {
		return nil, err
	}
	return awaitDeviceAttestation(ctx, ch, timeout)
}

func (c *Client) registerDeviceAttestationWaiter(
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

func awaitDeviceAttestation(ctx context.Context, ch <-chan *DeviceAttestationResponse, timeout time.Duration) (*DeviceAttestationResponse, error) {
	select {
	case resp := <-ch:
		return resp, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("device attestation wait cancelled: %w", ctx.Err())
	case <-time.After(timeout):
		return nil, errors.New("timeout waiting for DevicePropertiesAttestation")
	}
}
