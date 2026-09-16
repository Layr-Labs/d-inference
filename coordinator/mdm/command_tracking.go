package mdm

import (
	"time"
)

// outstandingCommand records a command UUID the coordinator issued, so the
// webhook can verify an inbound response was solicited.
type outstandingCommand struct {
	udid     string
	issuedAt time.Time
}

// outstandingCommandTTL bounds how long an issued command UUID stays valid for
// matching a webhook response. It must comfortably exceed the worst-case APN /
// Power Nap delivery delay (a sleeping Mac wakes on roughly a ~15-minute Power
// Nap cadence — see the late-SecurityInfo callback in cmd/coordinator/provider_trust.go),
// otherwise the UUID expires before a genuine SecurityInfo response arrives,
// consumeCommand drops it as stale, and the self_signed→hardware recovery path
// never fires. 30 minutes covers that delay while still bounding the forge
// window if a (random, localhost-only) UUID ever leaked.
const outstandingCommandTTL = 30 * time.Minute

// trackCommand records an issued command UUID so the webhook can confirm a
// later response was solicited. Prunes expired entries opportunistically.
func (c *Client) trackCommand(commandUUID, udid string, now time.Time) {
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
func (c *Client) consumeCommand(commandUUID string, now time.Time) (string, bool) {
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
