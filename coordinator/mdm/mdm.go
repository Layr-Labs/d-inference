// Package mdm provides integration with MicroMDM to independently verify
// provider device security posture.
//
// When a provider registers, the coordinator:
//  1. Looks up the device by serial number in MicroMDM
//  2. Verifies the device is enrolled (MDM profile installed)
//  3. Sends a SecurityInfo command to get hardware-verified SIP/SecureBoot status
//  4. Cross-checks the MDM response against the provider's self-reported attestation
//  5. Assigns trust level based on both
//
// This prevents providers from faking their attestation — the MDM SecurityInfo
// comes directly from Apple's MDM framework on the device, not from the
// provider's software.
package mdm

import (
	"crypto/tls"
	"log/slog"
	"net/http"
	"strings"
	"time"

	exchange "github.com/eigeninference/d-inference/coordinator/internal/mdm/exchange"
)

// OnMDACallback is called for a solicited DevicePropertiesAttestation response
// with no active exact waiter. The recipient must revalidate current connection
// and command ownership before applying the DER-encoded Apple cert chain.
type OnMDACallback func(udid, commandUUID string, certChain [][]byte)

// OnLateSecurityInfoCallback is called when a solicited SecurityInfo response
// arrives after its exact waiter has departed. The recipient must revalidate
// current connection and command ownership before applying it.
type OnLateSecurityInfoCallback func(
	udid, commandUUID string,
	info *exchange.SecurityInfoResponse,
)

// Client talks to the MicroMDM API.
type Client struct {
	baseURL   string
	apiKey    string
	client    *http.Client
	logger    *slog.Logger
	exchanges *exchange.Manager
	// Callback for MDA certs that arrive after the initial wait times out.
	onMDA OnMDACallback
	// Callback for SecurityInfo responses that arrive after the waiter timed out.
	onLateSecInfo OnLateSecurityInfoCallback
}

// NewClient creates an MDM client.
func NewClient(baseURL, apiKey string, logger *slog.Logger) *Client {
	return NewClientWithExchanges(baseURL, apiKey, logger, exchange.New())
}

// NewClientWithExchanges binds transport to caller-owned command exchanges.
func NewClientWithExchanges(baseURL, apiKey string, logger *slog.Logger, exchanges *exchange.Manager) *Client {
	httpClient := &http.Client{
		Timeout: 10 * time.Second,
	}
	// When talking to localhost MDM, skip TLS verification since the cert
	// is issued for the public domain, not localhost/127.0.0.1.
	if strings.Contains(baseURL, "localhost") || strings.Contains(baseURL, "127.0.0.1") {
		httpClient.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}
	return &Client{
		baseURL:   baseURL,
		apiKey:    apiKey,
		client:    httpClient,
		logger:    logger,
		exchanges: exchanges,
	}
}

// SetOnMDA registers a callback for late-arriving MDA attestation certs.
func (c *Client) SetOnMDA(fn OnMDACallback) {
	c.onMDA = fn
}

// SetOnLateSecurityInfo registers a callback for SecurityInfo responses that
// arrive after the synchronous waiter has timed out. This enables the
// coordinator to retroactively upgrade providers when APN delivery is slow.
func (c *Client) SetOnLateSecurityInfo(fn OnLateSecurityInfoCallback) {
	c.onLateSecInfo = fn
}
