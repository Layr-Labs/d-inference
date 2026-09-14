package mdm

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"time"
)

// HandleWebhook processes a MicroMDM webhook payload and extracts
// SecurityInfo and DevicePropertiesAttestation responses.
func (c *Client) HandleWebhook(body []byte) {
	var webhook struct {
		Topic string `json:"topic"`
		Event struct {
			UDID       string `json:"udid"`
			Status     string `json:"status"`
			RawPayload string `json:"raw_payload"`
		} `json:"acknowledge_event"`
	}

	if err := json.Unmarshal(body, &webhook); err != nil {
		c.logger.Debug("mdm webhook parse failed", "error", err)
		return
	}

	c.logger.Info("mdm webhook parsed",
		"topic", webhook.Topic,
		"status", webhook.Event.Status,
		"has_payload", webhook.Event.RawPayload != "",
	)

	if webhook.Event.Status != "Acknowledged" || webhook.Event.RawPayload == "" {
		return
	}

	// Decode the base64 plist payload
	plistData, err := base64.StdEncoding.DecodeString(webhook.Event.RawPayload)
	if err != nil {
		c.logger.Debug("mdm webhook base64 decode failed", "error", err)
		return
	}

	hasSecInfo := bytes.Contains(plistData, []byte("SecurityInfo"))
	hasDeviceAttest := bytes.Contains(plistData, []byte("DevicePropertiesAttestation"))

	// SOLICITED-RESPONSE GATE. Only honor a response whose CommandUUID matches a
	// command the coordinator issued. The structured SecurityInfo endpoint may
	// auto-push before returning its generated UUID; during that narrow window
	// buffer one bounded response on the already-exclusive waiter and deliver it
	// only after the returned UUID binds exactly.
	cmdUUID := parseCommandUUID(plistData)
	trackedUDID, solicited := c.consumeCommand(cmdUUID, time.Now())
	if !solicited {
		if hasSecInfo {
			secInfo := parseSecurityInfoPlist(plistData)
			if secInfo != nil {
				secInfo.UDID = webhook.Event.UDID
				if c.bufferEarlySecurityInfo(
					secInfo.UDID, cmdUUID, secInfo,
				) {
					c.logger.Info("mdm SecurityInfo buffered until command UUID binding")
					return
				}
			}
		}
		c.logger.Warn("mdm webhook dropped: unsolicited or unknown command")
		return
	}
	// Defense in depth: the response's device must be the one we addressed.
	if trackedUDID != "" && webhook.Event.UDID != "" &&
		trackedUDID != webhook.Event.UDID {
		c.logger.Warn("mdm webhook dropped: command/device mismatch")
		return
	}
	c.logger.Info("mdm webhook plist content",
		"size", len(plistData),
		"has_security_info", hasSecInfo,
		"has_device_attestation", hasDeviceAttest,
	)

	// Parse the plist for SecurityInfo
	secInfo := parseSecurityInfoPlist(plistData)
	if secInfo != nil {
		secInfo.UDID = webhook.Event.UDID
		c.logger.Info("mdm SecurityInfo received",
			"sip", secInfo.SystemIntegrityProtectionEnabled,
			"secure_boot", secInfo.SecureBootLevel,
			"auth_root_volume", secInfo.AuthenticatedRootVolumeEnabled,
		)
		c.waitMu.Lock()
		waiter, waiting := c.secInfoWaiters[secInfo.UDID]
		buffered := false
		owned := waiting && waiter.commandUUID == cmdUUID
		if waiting && waiter.commandUUID == "" {
			if waiter.early == nil {
				waiter.early = make(map[string]*SecurityInfoResponse)
			}
			if _, exists := waiter.early[cmdUUID]; exists ||
				len(waiter.early) < maxEarlySecurityInfoResponses {
				waiter.early[cmdUUID] = secInfo
				c.secInfoWaiters[secInfo.UDID] = waiter
				buffered = true
			}
		} else if owned {
			delete(c.secInfoWaiters, secInfo.UDID)
		}
		c.waitMu.Unlock()
		if buffered {
			c.logger.Info("mdm SecurityInfo buffered until waiter UUID binding")
		} else if owned {
			waiter.ch <- secInfo
		} else if waiting {
			c.logger.Warn("mdm SecurityInfo dropped: response belongs to an older command")
		} else if c.onLateSecInfo != nil {
			c.logger.Info("mdm SecurityInfo arrived late; invoking callback")
			c.onLateSecInfo(secInfo.UDID, cmdUUID, secInfo)
		} else {
			c.logger.Debug("mdm SecurityInfo dropped: no waiter or callback")
		}
	}

	// Parse the plist for DevicePropertiesAttestation
	attestCerts := parseDeviceAttestationPlist(plistData)
	if attestCerts != nil {
		resp := &DeviceAttestationResponse{
			UDID:      webhook.Event.UDID,
			CertChain: attestCerts,
		}
		c.logger.Info("mdm DevicePropertiesAttestation received",
			"cert_count", len(resp.CertChain),
		)
		c.waitMu.Lock()
		waiter, waiting := c.attestWaiters[resp.UDID]
		owned := waiting && waiter.commandUUID == cmdUUID
		unbound := waiting && waiter.commandUUID == ""
		if owned {
			delete(c.attestWaiters, resp.UDID)
		}
		c.waitMu.Unlock()
		if owned {
			waiter.ch <- resp
		} else if unbound && c.onMDA != nil {
			// The new raw command has not been published yet. Preserve the
			// response as late work for its exact prior scheduler generation;
			// never let it consume the replacement's unbound waiter.
			c.onMDA(resp.UDID, cmdUUID, resp.CertChain)
		} else if waiting {
			c.logger.Warn("mdm attestation dropped: response belongs to an older command")
		} else if c.onMDA != nil {
			c.onMDA(resp.UDID, cmdUUID, resp.CertChain)
		} else {
			c.logger.Debug("mdm attestation response dropped: no waiter or callback")
		}
	}
}
