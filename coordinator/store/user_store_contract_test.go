package store

import "testing"

func TestUserStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testUserStoreContract(t, st)
		})
	}
}

func testUserStoreContract(t *testing.T, st Store) {
	t.Helper()

	accountID := uniqueID("user-account")
	privyID := uniqueID("did-privy")
	email := uniqueID("user") + "@example.test"
	stripeID := uniqueID("acct")
	user := &User{
		AccountID:   accountID,
		PrivyUserID: privyID,
		Email:       email,
	}
	if err := st.CreateUser(user); err != nil {
		t.Fatalf("create user: %v", err)
	}

	assertUser := func(label string, got *User, err error, wantRole string, wantFee *int64) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		if got.AccountID != accountID ||
			got.PrivyUserID != privyID ||
			got.Email != email ||
			got.Role != wantRole {
			t.Fatalf("%s mismatch: %+v", label, got)
		}
		if wantFee == nil {
			if got.PlatformFeePercent != nil {
				t.Fatalf("%s fee = %v, want default nil", label, *got.PlatformFeePercent)
			}
		} else if got.PlatformFeePercent == nil || *got.PlatformFeePercent != *wantFee {
			t.Fatalf("%s fee = %v, want %d", label, got.PlatformFeePercent, *wantFee)
		}
	}
	got, err := st.GetUserByAccountID(accountID)
	assertUser("fresh user by account", got, err, "", nil)
	got, err = st.GetUserByPrivyID(privyID)
	assertUser("fresh user by Privy ID", got, err, "", nil)
	got, err = st.GetUserByEmail(email)
	assertUser("fresh user by email", got, err, "", nil)

	if err := st.SetUserRole(accountID, RoleService); err != nil {
		t.Fatalf("set role: %v", err)
	}
	zero := int64(0)
	if err := st.SetUserPlatformFeePercent(accountID, &zero); err != nil {
		t.Fatalf("waive platform fee: %v", err)
	}
	zero = 99
	wantZero := int64(0)
	got, err = st.GetUserByAccountID(accountID)
	assertUser("updated service user", got, err, RoleService, &wantZero)

	if err := st.SetUserRole(accountID, ""); err != nil {
		t.Fatalf("clear role: %v", err)
	}
	if got, err := st.GetUserByAccountID(accountID); err != nil || got.Role != "" {
		t.Fatalf("role after clear = %+v err=%v", got, err)
	}
	if err := st.SetUserRole(accountID, RoleService); err != nil {
		t.Fatalf("restore role: %v", err)
	}
	if err := st.SetUserRole(uniqueID("missing-account"), RoleService); err == nil {
		t.Fatal("set role for missing user succeeded")
	}

	fee := int64(250)
	if err := st.SetUserPlatformFeePercent(accountID, &fee); err != nil {
		t.Fatalf("set fee: %v", err)
	}
	fee = 999
	if got, err := st.GetUserByAccountID(accountID); err != nil ||
		got.PlatformFeePercent == nil ||
		*got.PlatformFeePercent != 250 {
		t.Fatalf("fee after set = %+v err=%v", got, err)
	}
	if err := st.SetUserPlatformFeePercent(accountID, nil); err != nil {
		t.Fatalf("clear fee: %v", err)
	}
	if got, err := st.GetUserByAccountID(accountID); err != nil || got.PlatformFeePercent != nil {
		t.Fatalf("fee after clear = %+v err=%v", got, err)
	}
	if err := st.SetUserPlatformFeePercent(uniqueID("missing-account"), &fee); err == nil {
		t.Fatal("set fee for missing user succeeded")
	}

	if err := st.SetUserStripeAccount(accountID, stripeID, "ready", "US", "card", "4242", true); err != nil {
		t.Fatalf("set Stripe account: %v", err)
	}
	got, err = st.GetUserByAccountID(accountID)
	if err != nil {
		t.Fatalf("get Stripe user: %v", err)
	}
	if got.StripeAccountID != stripeID ||
		got.StripeAccountStatus != "ready" ||
		got.StripeAccountCountry != "US" ||
		got.StripeDestinationType != "card" ||
		got.StripeDestinationLast4 != "4242" ||
		!got.StripeInstantEligible {
		t.Fatalf("Stripe fields mismatch: %+v", got)
	}
	if err := st.SetUserStripeAccount(accountID, stripeID, "restricted", "", "bank", "6789", false); err != nil {
		t.Fatalf("update Stripe account: %v", err)
	}
	got, err = st.GetUserByStripeAccount(stripeID)
	if err != nil {
		t.Fatalf("get by Stripe account: %v", err)
	}
	if got.AccountID != accountID ||
		got.StripeAccountCountry != "US" ||
		got.StripeAccountStatus != "restricted" ||
		got.StripeDestinationType != "bank" ||
		got.StripeDestinationLast4 != "6789" ||
		got.StripeInstantEligible {
		t.Fatalf("updated Stripe fields mismatch: %+v", got)
	}
	if err := st.SetUserStripeAccount(uniqueID("missing-account"), stripeID, "pending", "", "", "", false); err == nil {
		t.Fatal("set Stripe account for missing user succeeded")
	}
}
