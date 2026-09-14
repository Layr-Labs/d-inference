package registry

import (
	"testing"
	"time"
)

func TestRecordChallengeSuccess(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	// Record some transient failures first
	reg.RecordChallengeFailure("p1", true)
	reg.RecordChallengeFailure("p1", true)

	// Now record success (provider was never untrusted -> not a recovery)
	if reg.RecordChallengeSuccess("p1") {
		t.Error("RecordChallengeSuccess should report recovery=false for a non-untrusted provider")
	}

	if p.FailedChallenges != 0 {
		t.Errorf("failed_challenges = %d, want 0 after success", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("last_challenge_verified should be set")
	}
	if !p.ChallengeVerifiedSIP {
		t.Error("recording challenge success should mark SIP as challenge verified")
	}
}

func TestRecordChallengeFailureTransient(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Transient (timeout) failure: should NOT clear routing below threshold.
	count := reg.RecordChallengeFailure("p1", true)
	if count != 1 {
		t.Errorf("failure count = %d, want 1", count)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("single transient failure should NOT clear last_challenge_verified")
	}

	reg.RecordChallengeFailure("p1", true) // 2
	if p.LastChallengeVerified.IsZero() {
		t.Error("two transient failures should NOT clear last_challenge_verified")
	}

	// Third transient failure hits threshold — now clear.
	reg.RecordChallengeFailure("p1", true) // 3
	if !p.LastChallengeVerified.IsZero() {
		t.Error("at MaxFailedChallenges, transient failures should clear last_challenge_verified")
	}
}

func TestRecordChallengeFailureSecurity(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Security failure (e.g. SIP disabled): clears routing immediately.
	count := reg.RecordChallengeFailure("p1", false)
	if count != 1 {
		t.Errorf("failure count = %d, want 1", count)
	}
	if !p.LastChallengeVerified.IsZero() {
		t.Error("security failure should clear last_challenge_verified immediately")
	}
	if p.ChallengeVerifiedSIP {
		t.Error("security failure should clear SIP verification immediately")
	}
}

func TestChallengeFailureThreshold(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Record failures up to the threshold (security failures)
	for range 3 {
		reg.RecordChallengeFailure("p1", false)
	}

	// The caller (handleChallengeFailure) is responsible for calling MarkUntrusted,
	// not RecordChallengeFailure itself. Let's verify the count is correct.
	p := reg.GetProvider("p1")
	if p.FailedChallenges != 3 {
		t.Errorf("failed_challenges = %d, want 3", p.FailedChallenges)
	}
}
