package store

import "testing"

// exerciseSelfRouteOnlyRoundTrip runs the full lifecycle of the SelfRouteOnly
// flag against any Store implementation: create → authenticate → get → update
// (off then on) → rotate. It is shared by the memory and Postgres suites so a
// schema/scan/INSERT/UPDATE drift in either backend is caught.
func exerciseSelfRouteOnlyRoundTrip(t *testing.T, s Store) {
	t.Helper()

	raw, rec, err := s.CreateAPIKey("acct-self", APIKeyCreate{Name: "my-machine", SelfRouteOnly: true})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	if !rec.SelfRouteOnly {
		t.Fatalf("create did not persist SelfRouteOnly=true")
	}

	// The request path reads the flag off the AuthenticateKey result.
	got, err := s.AuthenticateKey(raw)
	if err != nil {
		t.Fatalf("AuthenticateKey: %v", err)
	}
	if !got.SelfRouteOnly {
		t.Fatalf("AuthenticateKey lost SelfRouteOnly")
	}

	byID, err := s.GetAPIKeyByID("acct-self", rec.ID)
	if err != nil {
		t.Fatalf("GetAPIKeyByID: %v", err)
	}
	if !byID.SelfRouteOnly {
		t.Fatalf("GetAPIKeyByID lost SelfRouteOnly")
	}

	// Toggle off via update.
	mut := *byID
	mut.SelfRouteOnly = false
	upd, err := s.UpdateAPIKey("acct-self", rec.ID, mut)
	if err != nil {
		t.Fatalf("UpdateAPIKey(off): %v", err)
	}
	if upd.SelfRouteOnly {
		t.Fatalf("UpdateAPIKey did not clear SelfRouteOnly")
	}

	// Toggle back on, then confirm rotate preserves it.
	mut.SelfRouteOnly = true
	if _, err := s.UpdateAPIKey("acct-self", rec.ID, mut); err != nil {
		t.Fatalf("UpdateAPIKey(on): %v", err)
	}
	_, rotated, err := s.RotateAPIKey("acct-self", rec.ID)
	if err != nil {
		t.Fatalf("RotateAPIKey: %v", err)
	}
	if !rotated.SelfRouteOnly {
		t.Fatalf("RotateAPIKey dropped SelfRouteOnly")
	}

	// A key created without the flag defaults to false.
	_, plain, err := s.CreateAPIKey("acct-self", APIKeyCreate{Name: "normal"})
	if err != nil {
		t.Fatalf("CreateAPIKey(plain): %v", err)
	}
	if plain.SelfRouteOnly {
		t.Fatalf("plain key unexpectedly self_route_only")
	}
}

func TestMemorySelfRouteOnlyRoundTrip(t *testing.T) {
	exerciseSelfRouteOnlyRoundTrip(t, NewMemory(Config{}))
}

func TestPostgresSelfRouteOnlyRoundTrip(t *testing.T) {
	exerciseSelfRouteOnlyRoundTrip(t, testPostgresStore(t))
}
