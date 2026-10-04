package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRefundReservedBalanceDoesNotFinalizeWhenCreditFails(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	t.Cleanup(srv.Close)
	srv.fault.creditFailure.Store(true)

	pr := &registry.PendingRequest{
		RequestID:        "refund-credit-fails",
		Model:            "refund-credit-fails-model",
		ConsumerKey:      "test-key",
		ReservedMicroUSD: 50_000,
	}

	if ok := srv.reservations.Refund(pr, "forced-failure"); ok {
		t.Fatal("refundReservedBalance returned true despite store credit failure")
	}
	if ok := pr.MarkReservationFinalized(); !ok {
		t.Fatal("reservation was finalized even though refund credit failed")
	}
}
