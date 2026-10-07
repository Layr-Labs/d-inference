package mdm_test

import (
	"context"
	"errors"
	"testing"
	"time"

	exchange "github.com/eigeninference/d-inference/coordinator/internal/mdm/exchange"
)

func TestSecurityInfoWaiterRejectsOverlapAndCleansCancellation(t *testing.T) {
	c := testClient()
	ctx, cancel := context.WithCancel(context.Background())
	ch, _, release, err := c.RegisterSecurityInfoWaiter("UDID-ONE")
	if err != nil {
		t.Fatal(err)
	}
	firstDone := make(chan error, 1)
	go func() {
		_, err := exchange.AwaitSecurityInfo(ctx, ch, time.Minute)
		release()
		firstDone <- err
	}()
	if _, _, _, err := c.RegisterSecurityInfoWaiter(
		"UDID-ONE",
	); !errors.Is(err, exchange.ErrWaiterAlreadyRegistered) {
		t.Fatalf("overlap error = %v, want ErrWaiterAlreadyRegistered", err)
	}
	cancel()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v, want context.Canceled", err)
	}
	_, _, releaseNext, err := c.RegisterSecurityInfoWaiter("UDID-ONE")
	if err != nil {
		t.Fatal("cancelled SecurityInfo waiter was not removed")
	}
	releaseNext()
}

func TestMDAWaiterRejectsOverlapAndCleansCancellation(t *testing.T) {
	c := testClient()
	ctx, cancel := context.WithCancel(context.Background())
	ch, _, release, err := c.RegisterDeviceAttestationWaiter("UDID-MDA")
	if err != nil {
		t.Fatal(err)
	}
	firstDone := make(chan error, 1)
	go func() {
		_, err := exchange.AwaitDeviceAttestation(ctx, ch, time.Minute)
		release()
		firstDone <- err
	}()
	if _, _, _, err := c.RegisterDeviceAttestationWaiter(
		"UDID-MDA",
	); !errors.Is(err, exchange.ErrWaiterAlreadyRegistered) {
		t.Fatalf("overlap error = %v, want ErrWaiterAlreadyRegistered", err)
	}
	cancel()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel error = %v, want context.Canceled", err)
	}
	_, _, releaseNext, err := c.RegisterDeviceAttestationWaiter("UDID-MDA")
	if err != nil {
		t.Fatal("cancelled MDA waiter was not removed")
	}
	releaseNext()
}

func TestSecurityInfoIssuedCommandOwnershipIsExact(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.RegisterSecurityInfoWaiter("UDID-EXACT")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if !bind("new-command") {
		t.Fatal("failed to bind exact command owner")
	}
	lateCalls := 0
	c.SetOnLateSecurityInfo(func(string, string, *exchange.SecurityInfoResponse) { lateCalls++ })

	c.TrackCommand("old-command", "UDID-EXACT", time.Now())
	c.HandleWebhook(buildSecurityInfoWebhook("UDID-EXACT", "old-command"))
	select {
	case <-ch:
		t.Fatal("older command response satisfied the newer waiter")
	default:
	}
	if lateCalls != 0 {
		t.Fatal("older command response bypassed exact ownership through late callback")
	}

	c.TrackCommand("new-command", "UDID-EXACT", time.Now())
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
	ch, bind, release, err := c.RegisterSecurityInfoWaiter("UDID-FAST")
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
	c.TrackCommand("fast-command", "UDID-FAST", time.Now())
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
	if _, ok := c.ConsumeCommand("fast-command", time.Now()); ok {
		t.Fatal("delivered buffered response left a reusable command UUID")
	}
}

func TestSecurityInfoTrackedResponseBuffersUntilWaiterBound(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.RegisterSecurityInfoWaiter("UDID-TRACKED-FAST")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	c.TrackCommand("tracked-fast-command", "UDID-TRACKED-FAST", time.Now())
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
	ch, bind, release, err := c.RegisterDeviceAttestationWaiter("UDID-MDA-EXACT")
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if !bind("mda-command") {
		t.Fatal("failed to bind MDA command owner")
	}
	if bind("replacement") {
		t.Fatal("bound MDA waiter accepted command owner replacement")
	}
	c.TrackCommand("mda-command", "UDID-MDA-EXACT", time.Now())
	c.HandleWebhook(buildDeviceAttestationWebhook("UDID-MDA-EXACT", "mda-command"))
	select {
	case got := <-ch:
		if got.UDID != "UDID-MDA-EXACT" {
			t.Fatal("MDA waiter did not retain exact UUID/UDID/channel ownership")
		}
	case <-time.After(time.Second):
		t.Fatal("MDA waiter did not retain exact UUID/UDID/channel ownership")
	}
}

func TestMDAOldResponseDoesNotConsumeUnboundReplacementWaiter(t *testing.T) {
	c := testClient()
	ch, bind, release, err := c.RegisterDeviceAttestationWaiter(
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
	c.TrackCommand(
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
