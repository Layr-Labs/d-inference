package registry

import (
	"testing"
)

func TestBenchmarkFieldsInRegistration(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrefillTPS = 500.0
	msg.DecodeTPS = 100.0

	p := reg.Register("p1", nil, msg)
	if p.PrefillTPS != 500.0 {
		t.Errorf("prefill_tps = %f, want 500.0", p.PrefillTPS)
	}
	if p.DecodeTPS != 100.0 {
		t.Errorf("decode_tps = %f, want 100.0", p.DecodeTPS)
	}
}

func TestRegisterAndGetProvider(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)

	if p.ID != "p1" {
		t.Errorf("id = %q, want %q", p.ID, "p1")
	}
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q", p.Status, StatusOnline)
	}
	if len(p.Models) != 1 {
		t.Errorf("models = %d, want 1", len(p.Models))
	}

	got := reg.GetProvider("p1")
	if got == nil {
		t.Fatal("GetProvider returned nil")
	}
	if got.ID != "p1" {
		t.Errorf("got id = %q", got.ID)
	}

	if reg.ProviderCount() != 1 {
		t.Errorf("count = %d, want 1", reg.ProviderCount())
	}
}
