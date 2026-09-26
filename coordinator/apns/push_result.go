package apns

import (
	"context"
	"encoding/json"
	"net/http"
)

// PushResult describes what APNs did with one code-identity push, without the
// device token, payload or free-form response text. Reason is a closed
// bucket (see ParseReason); StatusCode is 0 when no HTTP response arrived.
type PushResult struct {
	StatusCode    int
	Reason        string
	APNsIDPresent bool
	// Transport is set when the request was sent but no HTTP response arrived.
	Transport bool
	// LocalBackoff is set when a prior 429 Retry-After suppressed the send.
	LocalBackoff bool
}

// Closed APNs rejection reasons retained for diagnostics; everything else is
// ReasonOther. https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns
const (
	ReasonBadDeviceToken         = "BadDeviceToken"
	ReasonUnregistered           = "Unregistered"
	ReasonTooManyRequests        = "TooManyRequests"
	ReasonDeviceTokenNotForTopic = "DeviceTokenNotForTopic"
	ReasonExpiredProviderToken   = "ExpiredProviderToken"
	ReasonInternalServerError    = "InternalServerError"
	ReasonServiceUnavailable     = "ServiceUnavailable"
	ReasonOther                  = "other"
)

// ParseReason maps an APNs error body's "reason" to the closed set. A
// non-JSON body, a missing reason or any unlisted reason becomes ReasonOther.
func ParseReason(body []byte) string {
	var decoded struct {
		Reason string `json:"reason"`
	}
	if json.Unmarshal(body, &decoded) != nil {
		return ReasonOther
	}
	switch decoded.Reason {
	case ReasonBadDeviceToken, ReasonUnregistered, ReasonTooManyRequests, ReasonDeviceTokenNotForTopic,
		ReasonExpiredProviderToken, ReasonInternalServerError, ReasonServiceUnavailable:
		return decoded.Reason
	}
	return ReasonOther
}

// Outcome is the closed metric bucket for this push: sent_ok, throttled,
// transport_error, not_sent (a local failure before any request), or
// rejected_<reason> for every other HTTP status.
func (r PushResult) Outcome() string {
	switch {
	case r.StatusCode == http.StatusOK:
		return "sent_ok"
	case r.StatusCode == http.StatusTooManyRequests || r.LocalBackoff:
		return "throttled"
	case r.StatusCode != 0:
		return "rejected_" + reasonTag(r.Reason)
	case r.Transport:
		return "transport_error"
	default:
		return "not_sent"
	}
}

func reasonTag(reason string) string {
	switch reason {
	case ReasonBadDeviceToken:
		return "bad_device_token"
	case ReasonUnregistered:
		return "unregistered"
	case ReasonTooManyRequests:
		return "too_many_requests"
	case ReasonDeviceTokenNotForTopic:
		return "device_token_not_for_topic"
	case ReasonExpiredProviderToken:
		return "expired_provider_token"
	case ReasonInternalServerError:
		return "internal_server_error"
	case ReasonServiceUnavailable:
		return "service_unavailable"
	}
	return "other"
}

// ResultReporter is implemented by attestors that can describe each push.
// Its error is exactly what SendCodeChallenge returns for the same push.
type ResultReporter interface {
	SendCodeChallengeResult(ctx context.Context, deviceToken, environment, providerPubKeyB64, nonceB64 string) (PushResult, error)
}
