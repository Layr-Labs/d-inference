package modelloads

import (
	"testing"
	"time"
)

func TestCommandsZeroValueReservationAndDeadline(t *testing.T) {
	var commands Commands
	now := time.Date(2026, time.September, 13, 0, 0, 0, 0, time.UTC)
	if !commands.Reserve("session", "model", now) {
		t.Fatal("zero-value commands rejected the first reservation")
	}
	status := commands.Observe("session", "model")
	if !status.Pending || !status.Started || !status.StartedAt.Equal(now) || !status.ExpiresAt.Equal(now.Add(PendingTTL)) {
		t.Fatalf("reservation clocks = %+v, want start %v and deadline %v", status, now, now.Add(PendingTTL))
	}
	if commands.Reserve("session", "other", now) {
		t.Fatal("a second model reserved the same pending session")
	}
	if count := commands.Count(status.ExpiresAt); count != 1 {
		t.Fatalf("count at exact deadline = %d, want 1", count)
	}
	if count := commands.Count(status.ExpiresAt.Add(time.Nanosecond)); count != 0 {
		t.Fatalf("count after deadline = %d, want 0", count)
	}
	if status := commands.Observe("session", "model"); status.Pending || status.Started {
		t.Fatalf("expiry retained coupled command clocks: %+v", status)
	}
	if !commands.Reserve("session", "other", now) {
		t.Fatal("expiry did not allow a replacement reservation")
	}
	if started := commands.Complete("session", "other"); !started.Equal(now) {
		t.Fatalf("completion start = %v, want %v", started, now)
	}
	if status := commands.Observe("session", "other"); status.Pending || status.Started {
		t.Fatalf("completion retained coupled command clocks: %+v", status)
	}
}
