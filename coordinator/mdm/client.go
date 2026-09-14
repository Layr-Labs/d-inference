package mdm

import (
	"crypto/tls"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Client talks to the MicroMDM API.
type Client struct {
	baseURL string
	apiKey  string
	client  *http.Client
	logger  *slog.Logger
	// Per-UDID exclusive waiters retain the exact issued CommandUUID. A late
	// response from an older attempt can never satisfy a newer waiter for the
	// same device.
	waitMu         sync.Mutex
	secInfoWaiters map[string]securityInfoWaiter
	attestWaiters  map[string]deviceAttestationWaiter
	// Callback for MDA certs that arrive after the initial wait times out.
	onMDA OnMDACallback
	// Callback for SecurityInfo responses that arrive after the waiter timed out.
	onLateSecInfo OnLateSecurityInfoCallback

	// outstanding tracks command UUIDs the coordinator has issued but not yet
	// matched to a response. The webhook only honors a response whose
	// CommandUUID is here — this is what makes the (unauthenticated) MicroMDM
	// callback safe: a caller can only ANSWER a command we actually issued, it
	// can never volunteer an unsolicited "SIP=true" to forge a trust upgrade.
	// Keyed by command UUID (a random, non-public identifier).
	outstandingMu sync.Mutex
	outstanding   map[string]outstandingCommand
}

// NewClient creates an MDM client.
func NewClient(baseURL, apiKey string, logger *slog.Logger) *Client {
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
		baseURL:        baseURL,
		apiKey:         apiKey,
		client:         httpClient,
		logger:         logger,
		secInfoWaiters: make(map[string]securityInfoWaiter),
		attestWaiters:  make(map[string]deviceAttestationWaiter),
		outstanding:    make(map[string]outstandingCommand),
	}
}

// ErrWaiterAlreadyRegistered is returned when command ownership for a UDID is
// already held by another live attempt. Overwriting a waiter could route a
// response to the wrong verification job.
var ErrWaiterAlreadyRegistered = errors.New("mdm waiter already registered")

// OnMDACallback is called for a solicited DevicePropertiesAttestation response
// with no active exact waiter. The recipient must revalidate current connection
// and command ownership before applying the DER-encoded Apple cert chain.
type OnMDACallback func(udid, commandUUID string, certChain [][]byte)

// OnLateSecurityInfoCallback is called when a solicited SecurityInfo response
// arrives after its exact waiter has departed. The recipient must revalidate
// current connection and command ownership before applying it.
type OnLateSecurityInfoCallback func(
	udid, commandUUID string,
	info *SecurityInfoResponse,
)

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
