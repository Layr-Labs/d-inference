package apns_test

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

func TestParseReasonClosedSet(t *testing.T) {
	for body, want := range map[string]string{
		`{"reason":"BadDeviceToken"}`:                 production.ReasonBadDeviceToken,
		`{"reason":"Unregistered","timestamp":1}`:     production.ReasonUnregistered,
		`{"reason":"TooManyRequests"}`:                production.ReasonTooManyRequests,
		`{"reason":"DeviceTokenNotForTopic"}`:         production.ReasonDeviceTokenNotForTopic,
		`{"reason":"ExpiredProviderToken"}`:           production.ReasonExpiredProviderToken,
		`{"reason":"InternalServerError"}`:            production.ReasonInternalServerError,
		`{"reason":"ServiceUnavailable"}`:             production.ReasonServiceUnavailable,
		`{"reason":"TopicDisallowed"}`:                production.ReasonOther,
		`{"reason":"badDeviceToken"}`:                 production.ReasonOther,
		`{"reason":"<script>device abc123</script>"}`: production.ReasonOther,
		`{}`:                    production.ReasonOther,
		`{"reason":7}`:          production.ReasonOther,
		`<html>502 Bad Gateway`: production.ReasonOther,
		``:                      production.ReasonOther,
	} {
		if got := production.ParseReason([]byte(body)); got != want {
			t.Fatalf("ParseReason(%q) = %q, want %q", body, got, want)
		}
	}
}

func TestPushResultOutcomeBuckets(t *testing.T) {
	for _, tc := range []struct {
		result production.PushResult
		want   string
	}{
		{production.PushResult{StatusCode: 200, APNsIDPresent: true}, "sent_ok"},
		{production.PushResult{StatusCode: 429, Reason: production.ReasonTooManyRequests}, "throttled"},
		{production.PushResult{LocalBackoff: true}, "throttled"},
		{production.PushResult{StatusCode: 400, Reason: production.ReasonBadDeviceToken}, "rejected_bad_device_token"},
		{production.PushResult{StatusCode: 410, Reason: production.ReasonUnregistered}, "rejected_unregistered"},
		{production.PushResult{StatusCode: 400, Reason: production.ReasonDeviceTokenNotForTopic}, "rejected_device_token_not_for_topic"},
		{production.PushResult{StatusCode: 403, Reason: production.ReasonExpiredProviderToken}, "rejected_expired_provider_token"},
		{production.PushResult{StatusCode: 500, Reason: production.ReasonInternalServerError}, "rejected_internal_server_error"},
		{production.PushResult{StatusCode: 503, Reason: production.ReasonServiceUnavailable}, "rejected_service_unavailable"},
		{production.PushResult{StatusCode: 400, Reason: production.ReasonOther}, "rejected_other"},
		{production.PushResult{StatusCode: 502}, "rejected_other"},
		{production.PushResult{Transport: true}, "transport_error"},
		{production.PushResult{}, "not_sent"},
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
		{410, `{"reason":"Unregistered","timestamp":1700000000000}`, "abc", "rejected_unregistered", production.ReasonUnregistered, true, true},
		{400, `{"reason":"BadDeviceToken"}`, "", "rejected_bad_device_token", production.ReasonBadDeviceToken, true, false},
		{429, `{"reason":"TooManyRequests"}`, "", "throttled", production.ReasonTooManyRequests, true, false},
		{502, `upstream proxy error`, "", "rejected_other", production.ReasonOther, true, false},
	} {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if tc.apnsID != "" {
				w.Header().Set("apns-id", tc.apnsID)
			}
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.body))
		}))
		a := newTestAttestor(t, production.Config{HostOverride: ts.URL, HTTPClient: ts.Client()})
		result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce)
		legacy := newTestAttestor(t, production.Config{HostOverride: ts.URL, HTTPClient: ts.Client()})
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
	base := time.Unix(1_780_000_000, 0)
	now := base
	a := newTestAttestor(t, production.Config{
		HostOverride: ts.URL,
		HTTPClient:   ts.Client(),
		Now:          func() time.Time { return now },
	})
	_, _ = a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce)
	if result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce); err == nil || result.Outcome() != "throttled" || !result.LocalBackoff {
		t.Fatalf("local backoff not reported as throttled: %+v %v", result, err)
	}
	ts.Close()
	now = base.Add(time.Hour)
	if result, err := a.SendCodeChallengeResult(context.Background(), "tok", "production", pub, nonce); err == nil || result.Outcome() != "transport_error" {
		t.Fatalf("closed server not a transport error: %+v %v", result, err)
	}
	if result, err := a.SendCodeChallengeResult(context.Background(), "", "production", pub, nonce); err == nil || result.Outcome() != "not_sent" {
		t.Fatalf("empty token not reported as not_sent: %+v %v", result, err)
	}
}
