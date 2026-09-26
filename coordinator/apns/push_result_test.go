package apns

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

func TestParseReasonClosedSet(t *testing.T) {
	for body, want := range map[string]string{
		`{"reason":"BadDeviceToken"}`:                 ReasonBadDeviceToken,
		`{"reason":"Unregistered","timestamp":1}`:     ReasonUnregistered,
		`{"reason":"TooManyRequests"}`:                ReasonTooManyRequests,
		`{"reason":"DeviceTokenNotForTopic"}`:         ReasonDeviceTokenNotForTopic,
		`{"reason":"ExpiredProviderToken"}`:           ReasonExpiredProviderToken,
		`{"reason":"InternalServerError"}`:            ReasonInternalServerError,
		`{"reason":"ServiceUnavailable"}`:             ReasonServiceUnavailable,
		`{"reason":"TopicDisallowed"}`:                ReasonOther,
		`{"reason":"badDeviceToken"}`:                 ReasonOther,
		`{"reason":"<script>device abc123</script>"}`: ReasonOther,
		`{}`:                    ReasonOther,
		`{"reason":7}`:          ReasonOther,
		`<html>502 Bad Gateway`: ReasonOther,
		``:                      ReasonOther,
	} {
		if got := ParseReason([]byte(body)); got != want {
			t.Fatalf("ParseReason(%q) = %q, want %q", body, got, want)
		}
	}
}

func TestPushResultOutcomeBuckets(t *testing.T) {
	for _, tc := range []struct {
		result PushResult
		want   string
	}{
		{PushResult{StatusCode: 200, APNsIDPresent: true}, "sent_ok"},
		{PushResult{StatusCode: 429, Reason: ReasonTooManyRequests}, "throttled"},
		{PushResult{LocalBackoff: true}, "throttled"},
		{PushResult{StatusCode: 400, Reason: ReasonBadDeviceToken}, "rejected_bad_device_token"},
		{PushResult{StatusCode: 410, Reason: ReasonUnregistered}, "rejected_unregistered"},
		{PushResult{StatusCode: 400, Reason: ReasonDeviceTokenNotForTopic}, "rejected_device_token_not_for_topic"},
		{PushResult{StatusCode: 403, Reason: ReasonExpiredProviderToken}, "rejected_expired_provider_token"},
		{PushResult{StatusCode: 500, Reason: ReasonInternalServerError}, "rejected_internal_server_error"},
		{PushResult{StatusCode: 503, Reason: ReasonServiceUnavailable}, "rejected_service_unavailable"},
		{PushResult{StatusCode: 400, Reason: ReasonOther}, "rejected_other"},
		{PushResult{StatusCode: 502}, "rejected_other"},
		{PushResult{Transport: true}, "transport_error"},
		{PushResult{}, "not_sent"},
	} {
		if got := tc.result.Outcome(); got != tc.want {
			t.Fatalf("%+v: outcome %q, want %q", tc.result, got, tc.want)
		}
	}
}

func TestSendCodeChallengeResultDescribesPushWithoutChangingErrors(t *testing.T) {
	provider, _ := e2e.GenerateSessionKeys()
	pub := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonce := base64.StdEncoding.EncodeToString([]byte("nonce-nonce-nonce-nonce-nonce-32"))
	for _, tc := range []struct {
		status        int
		body, apnsID  string
		wantOutcome   string
		wantReason    string
		wantErr       bool
		wantIDPresent bool
	}{
		{200, "", "11111111-2222-3333-4444-555555555555", "sent_ok", "", false, true},
		{410, `{"reason":"Unregistered","timestamp":1700000000000}`, "abc", "rejected_unregistered", ReasonUnregistered, true, true},
		{400, `{"reason":"BadDeviceToken"}`, "", "rejected_bad_device_token", ReasonBadDeviceToken, true, false},
		{429, `{"reason":"TooManyRequests"}`, "", "throttled", ReasonTooManyRequests, true, false},
		{502, `upstream proxy error`, "", "rejected_other", ReasonOther, true, false},
	} {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if tc.apnsID != "" {
				w.Header().Set("apns-id", tc.apnsID)
			}
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.body))
		}))
		a := newTestAttestor(t, Config{HostOverride: ts.URL, HTTPClient: ts.Client()})
		result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce)
		legacy := newTestAttestor(t, Config{HostOverride: ts.URL, HTTPClient: ts.Client()})
		legacyErr := legacy.SendCodeChallenge(context.Background(), "tok", "production", pub, nonce)
		ts.Close()
		if (err != nil) != tc.wantErr || (legacyErr != nil) != tc.wantErr || (err != nil && err.Error() != legacyErr.Error()) {
			t.Fatalf("%d: error semantics changed: %v vs %v", tc.status, err, legacyErr)
		}
		if result.StatusCode != tc.status || result.Reason != tc.wantReason || result.APNsIDPresent != tc.wantIDPresent || result.Outcome() != tc.wantOutcome {
			t.Fatalf("%d: result %+v (outcome %s)", tc.status, result, result.Outcome())
		}
	}
}

func TestSendCodeChallengeResultLocalFailures(t *testing.T) {
	provider, _ := e2e.GenerateSessionKeys()
	pub := base64.StdEncoding.EncodeToString(provider.PublicKey[:])
	nonce := base64.StdEncoding.EncodeToString([]byte("nonce-nonce-nonce-nonce-nonce-32"))
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	a := newTestAttestor(t, Config{HostOverride: ts.URL, HTTPClient: ts.Client()})
	base := time.Unix(1_780_000_000, 0)
	a.now = func() time.Time { return base }
	_, _ = a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce)
	if result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce); err == nil || result.Outcome() != "throttled" || !result.LocalBackoff {
		t.Fatalf("local backoff not reported as throttled: %+v %v", result, err)
	}
	ts.Close()
	a.now = func() time.Time { return base.Add(time.Hour) }
	if result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce); err == nil || result.Outcome() != "transport_error" {
		t.Fatalf("closed server not a transport error: %+v %v", result, err)
	}
	if result, err := a.SendCodeChallengeResult(context.Background(), "", "production", pub, nonce); err == nil || result.Outcome() != "not_sent" {
		t.Fatalf("empty token not reported as not_sent: %+v %v", result, err)
	}
}
