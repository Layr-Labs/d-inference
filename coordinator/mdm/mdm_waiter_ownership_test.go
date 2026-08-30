package mdm

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSecurityInfoWaiterRejectsOverlapAndCleansCancellation(t *testing.T) {
	c := testClient()
	ctx, cancel := context.WithCancel(context.Background())
	ch, _, release, err := c.registerSecurityInfoWaiter("UDID-ONE")
	if err != nil {
		t.Fatal(err)
	}
	firstDone := make(chan error, 1)
	go func() {
		defer release()
		_, err := awaitSecurityInfo(ctx, ch, "UDID-ONE", time.Minute)
		firstDone <- err
	}()
	if _, _, _, err := c.registerSecurityInfoWaiter(
		"UDID-ONE",
	); !errors.Is(err, ErrWaiterAlreadyRegistered) {
		t.Fatalf("overlap error = %v, want ErrWaiterAlreadyRegistered", err)
	}
	cancel()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v, want context.Canceled", err)
	}
	c.waitMu.Lock()
	_, waiting := c.secInfoWaiters["UDID-ONE"]
	c.waitMu.Unlock()
	if waiting {
		t.Fatal("cancelled SecurityInfo waiter was not removed")
	}
}

func TestMDAWaiterRejectsOverlapAndCleansCancellation(t *testing.T) {
	c := testClient()
	ctx, cancel := context.WithCancel(context.Background())
	ch, _, release, err := c.registerDeviceAttestationWaiter("UDID-MDA")
	if err != nil {
		t.Fatal(err)
	}
	firstDone := make(chan error, 1)
	go func() {
		defer release()
		_, err := awaitDeviceAttestation(ctx, ch, "UDID-MDA", time.Minute)
		firstDone <- err
	}()
	if _, _, _, err := c.registerDeviceAttestationWaiter(
		"UDID-MDA",
	); !errors.Is(err, ErrWaiterAlreadyRegistered) {
		t.Fatalf("overlap error = %v, want ErrWaiterAlreadyRegistered", err)
	}
	cancel()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v, want context.Canceled", err)
	}
	c.waitMu.Lock()
	_, waiting := c.attestWaiters["UDID-MDA"]
	c.waitMu.Unlock()
	if waiting {
		t.Fatal("cancelled MDA waiter was not removed")
	}
}

func TestSecurityInfoIssuedCommandOwnershipIsExact(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.registerSecurityInfoWaiter("UDID-EXACT")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if !bind("new-command") {
		t.Fatal("failed to bind exact command owner")
	}
	lateCalls := 0
	c.SetOnLateSecurityInfo(func(string, string, *SecurityInfoResponse) { lateCalls++ })

	c.trackCommand("old-command", "UDID-EXACT", time.Now())
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-EXACT", "old-command"))
	select {
	case <-ch:
		t.Fatal("older command response satisfied the newer waiter")
	default:
	}
	if lateCalls != 0 {
		t.Fatal("older command response bypassed exact ownership through late callback")
	}

	c.trackCommand("new-command", "UDID-EXACT", time.Now())
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-EXACT", "new-command"))
	select {
	case got := <-ch:
		if got.UDID != "UDID-EXACT" {
			t.Fatalf("response UDID = %q", got.UDID)
		}
	case <-time.After(time.Second):
		t.Fatal("exact command response was not delivered")
	}
}

func TestSecurityInfoFastResponseBuffersUntilCommandUUIDBound(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.registerSecurityInfoWaiter("UDID-FAST")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-FAST", "fast-command"))
	select {
	case <-ch:
		t.Fatal("unbound response was delivered before command UUID verification")
	default:
	}
	c.trackCommand("fast-command", "UDID-FAST", time.Now())
	if !bind("fast-command") {
		t.Fatal("returned command UUID did not bind the buffered response")
	}
	select {
	case got := <-ch:
		if got.UDID != "UDID-FAST" {
			t.Fatalf("buffered response UDID = %q", got.UDID)
		}
	case <-time.After(time.Second):
		t.Fatal("exact buffered response was not delivered after binding")
	}
	if _, ok := c.consumeCommand("fast-command", time.Now()); ok {
		t.Fatal("delivered buffered response left a reusable command UUID")
	}
}

func TestSecurityInfoTrackedResponseBuffersUntilWaiterBound(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.registerSecurityInfoWaiter("UDID-TRACKED-FAST")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	c.trackCommand("tracked-fast-command", "UDID-TRACKED-FAST", time.Now())
	c.HandleWebhook(buildSecurityInfoWebhook(
		"UDID-TRACKED-FAST", "tracked-fast-command",
	))
	select {
	case <-ch:
		t.Fatal("tracked response was delivered before waiter UUID binding")
	default:
	}
	if !bind("tracked-fast-command") {
		t.Fatal("waiter did not bind the already-consumed tracked response")
	}
	select {
	case got := <-ch:
		if got.UDID != "UDID-TRACKED-FAST" {
			t.Fatalf("tracked buffered response UDID = %q", got.UDID)
		}
	case <-time.After(time.Second):
		t.Fatal("tracked fast response was not delivered after binding")
	}
}

func TestMDAIssuedCommandOwnershipIsExact(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.registerDeviceAttestationWaiter("UDID-MDA-EXACT")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if !bind("mda-command") {
		t.Fatal("failed to bind MDA command owner")
	}
	c.waitMu.Lock()
	owner := c.attestWaiters["UDID-MDA-EXACT"]
	c.waitMu.Unlock()
	if owner.commandUUID != "mda-command" || owner.ch != ch {
		t.Fatal("MDA waiter did not retain exact UUID/UDID/channel ownership")
	}
	if bind("replacement") {
		t.Fatal("bound MDA waiter accepted command owner replacement")
	}
}

func TestMDAOldResponseDoesNotConsumeUnboundReplacementWaiter(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.registerDeviceAttestationWaiter(
		"UDID-MDA-REPLACEMENT",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	lateCalls := 0
	c.SetOnMDA(func(udid, commandUUID string, chain [][]byte) {
		if udid != "UDID-MDA-REPLACEMENT" ||
			commandUUID != "old-mda-command" ||
			len(chain) != 1 {
			t.Fatalf(
				"late MDA callback = %q/%q/%d certs",
				udid, commandUUID, len(chain),
			)
		}
		lateCalls++
	})
	c.trackCommand(
		"old-mda-command", "UDID-MDA-REPLACEMENT", time.Now(),
	)
	c.HandleWebhook(buildDeviceAttestationWebhook(
		"UDID-MDA-REPLACEMENT", "old-mda-command",
	))
	select {
	case <-ch:
		t.Fatal("old MDA response consumed the unbound replacement waiter")
	default:
	}
	if lateCalls != 1 {
		t.Fatalf("old MDA response late callbacks = %d, want 1", lateCalls)
	}
	if !bind("new-mda-command") {
		t.Fatal("old MDA response removed the replacement waiter")
	}
}
