package registry_test

// A committed pair is quarantined when it ends without both owner-release
// receipts. A member whose original connection is gone can never deliver its
// receipt, so that quarantine used to fence both machines (serial and Secure
// Enclave key) until the coordinator restarted, including for an ordinary solo
// registration. These tests pin the bounded release and the cases where the
// hold must still stand. They run on the fake clock of a synctest bubble
// through the public registry API only.

import (
	"fmt"
	"testing"
	"testing/synctest"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	gatePairReserved = "pair_reserved"
	gateEligible     = "eligible"
	// An owner anchors the fixed lifetime to its own clock and may lag the
	// coordinator by up to the thirty-second preparation limit, then retires.
	// The hold must outlast that and must not outlast a minute past expiry.
	ownerMayStillRun      = 30 * time.Second
	ownersMustHaveRetired = time.Minute
)

func committedPairFixture(t *testing.T, r *production.Registry) (*production.VerifiedPairHandle, production.VerifiedPairMembership, [2]*production.Provider) {
	t.Helper()
	members := [2]*production.Provider{
		pairMember(t, r, nil, "pair-a", "serial-a", fmt.Sprintf("%064x", 1)),
		pairMember(t, r, nil, "pair-b", "serial-b", fmt.Sprintf("%064x", 2)),
	}
	h, m, err := r.ReserveVerifiedPair(members, pairRequest())
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	for _, p := range members {
		if err = r.AcknowledgeVerifiedPairPrepared(h, p, m.TranscriptSHA256); err != nil {
			t.Fatalf("prepare: %v", err)
		}
	}
	if _, err = r.CommitVerifiedPairOwners(h); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return h, m, members
}

// soloGateOnPairDevice registers a fresh, fully trusted ordinary solo
// connection from the fixture device with that serial (same Secure Enclave
// key as its pair member), and returns the routing gate it meets for the
// model it holds idle. The gate reason and an actual reservation must agree.
// The solo connection is gone again when this returns.
func soloGateOnPairDevice(t *testing.T, r *production.Registry, serial string) string {
	t.Helper()
	id := "solo-" + serial
	solo := soloPairDevice(t, r, id, serial)
	defer r.Disconnect(id)

	reason := ""
	for _, row := range r.FleetSample(time.Now()) {
		if row.ProviderID == id && row.Model == nativePairFixtureModel {
			reason = row.EligibilityReason
		}
	}
	if reason == "" {
		t.Fatalf("no fleet sample row for the solo registration on %s", serial)
	}
	reserved := r.ReserveProvider(nativePairFixtureModel, &production.PendingRequest{RequestID: id}) == solo
	if reserved != (reason == gateEligible) {
		t.Fatalf("solo registration on %s: gate %q but reserved=%v", serial, reason, reserved)
	}
	return reason
}

func requireSoloGate(t *testing.T, r *production.Registry, want, when string) {
	t.Helper()
	for _, serial := range []string{"serial-a", "serial-b"} {
		if got := soloGateOnPairDevice(t, r, serial); got != want {
			t.Fatalf("%s: solo registration on %s meets gate %q, want %q", when, serial, got, want)
		}
	}
}

func sleepUntil(instant time.Time) {
	time.Sleep(time.Until(instant))
	synctest.Wait()
}

// The reported lockout: a member disconnects after commit and its machine
// comes back as an ordinary solo provider.
func TestQuarantinedPairReleasesAfterBothMembersLeaveAndOwnersRetire(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := pairEnvironment(t)
		h, m, members := committedPairFixture(t, r)

		r.Disconnect(members[0].ID)
		select {
		case <-h.Done():
		default:
			t.Fatal("disconnect did not publish invalidation")
		}
		requireSoloGate(t, r, gatePairReserved, "one member gone")

		r.Disconnect(members[1].ID)
		requireSoloGate(t, r, gatePairReserved, "both members gone before expiry")

		// Both control connections are gone, but an owner started under this
		// reservation may run until its fixed lifetime ends and then retire.
		sleepUntil(m.ExpiresAt.Add(ownerMayStillRun))
		requireSoloGate(t, r, gatePairReserved, "owners may still be running")

		sleepUntil(m.ExpiresAt.Add(ownersMustHaveRetired))
		requireSoloGate(t, r, gateEligible, "nothing can still run under the reservation")

		// The devices are selectable for a new pair too, and the old handle is spent.
		replacements := [2]*production.Provider{
			pairMember(t, r, nil, "pair-a2", "serial-a", fmt.Sprintf("%064x", 3)),
			pairMember(t, r, nil, "pair-b2", "serial-b", fmt.Sprintf("%064x", 4)),
		}
		next, _, err := r.ReserveVerifiedPair(replacements, pairRequest())
		if err != nil {
			t.Fatalf("released devices refused a new pair: %v", err)
		}
		if _, err = r.VerifiedPairStatus(h); err == nil {
			t.Fatal("released pair still answers for its old handle")
		}
		if err = r.CancelVerifiedPair(next); err != nil {
			t.Fatal(err)
		}
	})
}

// Time alone never releases a member that is still connected: its original
// connection can still deliver the authenticated owner-release receipt.
func TestQuarantinedPairHoldsWhileAMemberIsConnected(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := pairEnvironment(t)
		_, m, members := committedPairFixture(t, r)

		r.Disconnect(members[0].ID)
		sleepUntil(m.ExpiresAt.Add(10 * time.Minute))
		requireSoloGate(t, r, gatePairReserved, "peer still connected without a receipt")

		// The last connection leaves long after the owners must have retired:
		// nothing is left to wait for.
		r.Disconnect(members[1].ID)
		requireSoloGate(t, r, gateEligible, "last member gone after the bound")
	})
}

// A connected member that delivered its receipt is settled; the departed
// member's device still waits out the reservation.
func TestQuarantinedPairReleasesWithOneReceiptAndOneDepartedMember(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := pairEnvironment(t)
		h, m, members := committedPairFixture(t, r)

		r.Disconnect(members[0].ID)
		if err := r.ObserveVerifiedPairOwnerReleased(h, members[1], m.TranscriptSHA256); err != nil {
			t.Fatalf("connected member's receipt: %v", err)
		}
		sleepUntil(m.ExpiresAt.Add(ownerMayStillRun))
		requireSoloGate(t, r, gatePairReserved, "departed member's owner may still be running")

		sleepUntil(m.ExpiresAt.Add(ownersMustHaveRetired))
		requireSoloGate(t, r, gateEligible, "receipt plus departed member past the bound")
		r.Disconnect(members[1].ID)
	})
}

// The receipt of the last connected member settles the pair even when it
// arrives after the departed member's bound.
func TestQuarantinedPairReleasesOnLateReceiptAfterPeerDeparted(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := pairEnvironment(t)
		h, m, members := committedPairFixture(t, r)

		r.Disconnect(members[0].ID)
		sleepUntil(m.ExpiresAt.Add(5 * time.Minute))
		requireSoloGate(t, r, gatePairReserved, "connected member owes its receipt")

		if err := r.ObserveVerifiedPairOwnerReleased(h, members[1], m.TranscriptSHA256); err != nil {
			t.Fatalf("late receipt: %v", err)
		}
		requireSoloGate(t, r, gateEligible, "late receipt with the peer long gone")
		r.Disconnect(members[1].ID)
	})
}
