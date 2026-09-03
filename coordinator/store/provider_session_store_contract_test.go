package store

import (
	"context"
	"testing"
	"time"
)

func TestProviderSessionStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testProviderSessionStoreContract(t, st)
		})
	}
}

func testProviderSessionStoreContract(t *testing.T, st Store) {
	t.Helper()

	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	windowStart := now.Add(-time.Minute)
	windowEnd := now.Add(time.Hour)
	findSession := func(sessionID string) *ProviderSession {
		t.Helper()
		sessions, err := st.ListProviderSessionsOverlapping(ctx, windowStart, windowEnd, 10*time.Minute)
		if err != nil {
			t.Fatalf("list sessions: %v", err)
		}
		for i := range sessions {
			if sessions[i].SessionID == sessionID {
				return &sessions[i]
			}
		}
		return nil
	}

	sessionID := uniqueID("session")
	if err := st.OpenProviderSession(ctx, sessionID, "", ""); err != nil {
		t.Fatalf("open: %v", err)
	}
	touchAt := now.Add(time.Minute)
	if err := st.TouchProviderSession(ctx, sessionID, "SERIAL1", "ACCOUNT1", "KEY1", touchAt); err != nil {
		t.Fatalf("touch: %v", err)
	}
	session := findSession(sessionID)
	if session == nil ||
		session.SerialNumber != "SERIAL1" ||
		session.AccountID != "ACCOUNT1" ||
		session.ProviderKey != "KEY1" ||
		!session.LastSeen.Equal(touchAt) ||
		session.DisconnectedAt != nil {
		t.Fatalf("after touch: %+v", session)
	}

	secondTouch := now.Add(2 * time.Minute)
	if err := st.TouchProviderSession(ctx, sessionID, "SERIAL2", "ACCOUNT2", "KEY2", secondTouch); err != nil {
		t.Fatalf("second touch: %v", err)
	}
	session = findSession(sessionID)
	if session == nil ||
		session.SerialNumber != "SERIAL1" ||
		session.AccountID != "ACCOUNT1" ||
		session.ProviderKey != "KEY1" ||
		!session.LastSeen.Equal(secondTouch) {
		t.Fatalf("second touch overwrote identity or missed heartbeat: %+v", session)
	}

	closeAt := now.Add(3 * time.Minute)
	if err := st.CloseProviderSession(ctx, sessionID, "disconnect", closeAt); err != nil {
		t.Fatalf("close: %v", err)
	}
	session = findSession(sessionID)
	if session == nil ||
		session.DisconnectedAt == nil ||
		!session.DisconnectedAt.Equal(closeAt) ||
		session.DisconnectReason != "disconnect" {
		t.Fatalf("after close: %+v", session)
	}
	closedLastSeen := session.LastSeen
	if err := st.TouchProviderSession(ctx, sessionID, "X", "Y", "Z", closeAt.Add(time.Minute)); err != nil {
		t.Fatalf("touch closed session: %v", err)
	}
	session = findSession(sessionID)
	if session == nil || !session.LastSeen.Equal(closedLastSeen) {
		t.Fatalf("touch changed closed session: %+v", session)
	}

	raceID := uniqueID("close-before-open")
	raceCloseAt := now.Add(4 * time.Minute)
	if err := st.CloseProviderSession(ctx, raceID, "disconnect", raceCloseAt); err != nil {
		t.Fatalf("close before open: %v", err)
	}
	if err := st.OpenProviderSession(ctx, raceID, "RACE-SERIAL", "RACE-ACCOUNT"); err != nil {
		t.Fatalf("late open: %v", err)
	}
	raceSession := findSession(raceID)
	if raceSession == nil ||
		raceSession.DisconnectedAt == nil ||
		!raceSession.DisconnectedAt.Equal(raceCloseAt) {
		t.Fatalf("late open duplicated or reopened session: %+v", raceSession)
	}

	staleID := uniqueID("stale-session")
	freshID := uniqueID("fresh-session")
	if err := st.OpenProviderSession(ctx, staleID, "STALE", "ACCOUNT"); err != nil {
		t.Fatalf("open stale: %v", err)
	}
	if err := st.TouchProviderSession(ctx, staleID, "STALE", "ACCOUNT", "STALE-KEY", now.Add(time.Minute)); err != nil {
		t.Fatalf("touch stale: %v", err)
	}
	if err := st.OpenProviderSession(ctx, freshID, "FRESH", "ACCOUNT"); err != nil {
		t.Fatalf("open fresh: %v", err)
	}
	if err := st.TouchProviderSession(ctx, freshID, "FRESH", "ACCOUNT", "FRESH-KEY", now.Add(2*time.Minute)); err != nil {
		t.Fatalf("touch fresh: %v", err)
	}
	closed, err := st.CloseOpenProviderSessions(ctx, now.Add(90*time.Second))
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if closed != 1 {
		t.Fatalf("reconcile closed %d sessions, want 1", closed)
	}
	stale := findSession(staleID)
	if stale == nil ||
		stale.DisconnectedAt == nil ||
		!stale.DisconnectedAt.Equal(stale.LastSeen) ||
		stale.DisconnectReason != "coordinator_restart" {
		t.Fatalf("stale session not reconciled: %+v", stale)
	}
	fresh := findSession(freshID)
	if fresh == nil || fresh.DisconnectedAt != nil {
		t.Fatalf("fresh session was reconciled: %+v", fresh)
	}
	if closed, err := st.CloseOpenProviderSessions(ctx, now.Add(90*time.Second)); err != nil || closed != 0 {
		t.Fatalf("second reconcile = %d err=%v, want no-op", closed, err)
	}
}
