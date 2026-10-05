package exchange

type DeliveryStatus uint8

const (
	Unmatched DeliveryStatus = iota
	Owned
	Buffered
	OlderCommand
	Unbound
)

func (c *Manager) DeliverSecurityInfo(commandUUID string, resp *SecurityInfoResponse) DeliveryStatus {
	c.waitMu.Lock()
	waiter, waiting := c.secInfoWaiters[resp.UDID]
	buffered := false
	owned := waiting && waiter.commandUUID == commandUUID
	if waiting && waiter.commandUUID == "" {
		if waiter.early == nil {
			waiter.early = make(map[string]*SecurityInfoResponse)
		}
		if _, exists := waiter.early[commandUUID]; exists || len(waiter.early) < maxEarlySecurityInfoResponses {
			waiter.early[commandUUID] = resp
			c.secInfoWaiters[resp.UDID] = waiter
			buffered = true
		}
	} else if owned {
		delete(c.secInfoWaiters, resp.UDID)
	}
	c.waitMu.Unlock()
	if buffered {
		return Buffered
	}
	if owned {
		waiter.ch <- resp
		return Owned
	}
	if waiting {
		return OlderCommand
	}
	return Unmatched
}

func (c *Manager) DeliverDeviceAttestation(commandUUID string, resp *DeviceAttestationResponse) DeliveryStatus {
	c.waitMu.Lock()
	waiter, waiting := c.attestWaiters[resp.UDID]
	owned := waiting && waiter.commandUUID == commandUUID
	unbound := waiting && waiter.commandUUID == ""
	if owned {
		delete(c.attestWaiters, resp.UDID)
	}
	c.waitMu.Unlock()
	if owned {
		waiter.ch <- resp
		return Owned
	}
	if unbound {
		return Unbound
	}
	if waiting {
		return OlderCommand
	}
	return Unmatched
}
