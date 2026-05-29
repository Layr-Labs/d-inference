package store

import "testing"

func TestSetUserRole(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.CreateUser(&User{AccountID: "acct-1", PrivyUserID: "did:privy:1"}); err != nil {
		t.Fatal(err)
	}

	if err := s.SetUserRole("acct-1", RoleService); err != nil {
		t.Fatalf("SetUserRole: %v", err)
	}
	u, err := s.GetUserByAccountID("acct-1")
	if err != nil {
		t.Fatal(err)
	}
	if u.Role != RoleService {
		t.Errorf("role = %q, want %q", u.Role, RoleService)
	}

	// Clearing back to a normal account.
	if err := s.SetUserRole("acct-1", ""); err != nil {
		t.Fatal(err)
	}
	u, _ = s.GetUserByAccountID("acct-1")
	if u.Role != "" {
		t.Errorf("role after clear = %q, want empty", u.Role)
	}

	// Unknown account is an error.
	if err := s.SetUserRole("nope", RoleService); err == nil {
		t.Error("expected error for unknown account")
	}
}

func TestSetUserPlatformFeePercent(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.CreateUser(&User{AccountID: "acct-1", PrivyUserID: "did:privy:1"}); err != nil {
		t.Fatal(err)
	}

	// Default: nil override.
	u, _ := s.GetUserByAccountID("acct-1")
	if u.PlatformFeePercent != nil {
		t.Errorf("default fee override = %v, want nil", *u.PlatformFeePercent)
	}

	// Set 0% (waive fee).
	zero := int64(0)
	if err := s.SetUserPlatformFeePercent("acct-1", &zero); err != nil {
		t.Fatal(err)
	}
	u, _ = s.GetUserByAccountID("acct-1")
	if u.PlatformFeePercent == nil || *u.PlatformFeePercent != 0 {
		t.Errorf("fee override = %v, want 0", u.PlatformFeePercent)
	}

	// Stored pointer must not alias the caller's variable.
	zero = 99
	u, _ = s.GetUserByAccountID("acct-1")
	if *u.PlatformFeePercent != 0 {
		t.Errorf("stored fee mutated via caller alias = %d, want 0", *u.PlatformFeePercent)
	}

	// Clear back to nil.
	if err := s.SetUserPlatformFeePercent("acct-1", nil); err != nil {
		t.Fatal(err)
	}
	u, _ = s.GetUserByAccountID("acct-1")
	if u.PlatformFeePercent != nil {
		t.Errorf("fee after clear = %v, want nil", *u.PlatformFeePercent)
	}

	if err := s.SetUserPlatformFeePercent("nope", &zero); err == nil {
		t.Error("expected error for unknown account")
	}
}
