package registry

import (
	"bytes"
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestNativePairAppAttestConfiguredPairUsesOriginalSignedCommitAndRelease(t *testing.T) {
	f := newNativePairFixture(t)
	pairTestAppAttest(t, f.r, f.p[0], "machine-a")
	pairTestAppAttest(t, f.r, f.p[1], "machine-b")
	if err := f.c.Configure(f.n[1], appPairIntent(t, f, 1)); err != nil {
		t.Fatal(err)
	}
	requireNoConfiguredHold(t, f)
	if err := f.c.Configure(f.n[0], appPairIntent(t, f, 0)); err != nil {
		t.Fatal(err)
	}
	for rank := 0; rank < 2; rank++ {
		f.read(t, rank, protocol.TypeNativePairPrepare)
	}
	f.c.mu.Lock()
	s := f.n[0].session
	f.c.mu.Unlock()
	if s == nil || s.membership.TranscriptVersion != 2 {
		t.Fatal("typed configured hold absent")
	}
	for rank := 0; rank < 2; rank++ {
		if s.starts[rank].Common.MembershipTranscriptSHA256 != s.membership.TranscriptSHA256 {
			t.Fatal("typed commitment lost at native start")
		}
		b, _ := s.starts[rank].Canonical()
		if err := f.c.Handle(f.n[rank], appPairMessage(t, f, s, rank, protocol.TypeNativePairPrepared, b)); err != nil {
			t.Fatal(err)
		}
		if rank == 0 && f.phase(s) != VerifiedPairPending {
			t.Fatal("single ACK started owners")
		}
	}
	for rank := 0; rank < 2; rank++ {
		m := f.read(t, rank, protocol.TypeNativePairOwnerStart)
		b, _ := m.PayloadBytes()
		want, _ := s.starts[rank].Canonical()
		if !bytes.Equal(b, want) {
			t.Fatal("owner start substituted typed grant")
		}
	}
	if f.phase(s) != VerifiedPairActive {
		t.Fatal("original bilateral commit missing")
	}
	renewed := f.p[0].GetAppAttestServingAuthorization()
	renewed.ProofSessionID = "fresh-retry-proof"
	if !f.r.GrantAppAttestServingAuthorization(f.p[0], renewed) {
		t.Fatal("fresh same-connection proof")
	}
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("proof renewal reopened original admission")
	}
	f.c.Cancel(s)
	for rank := 0; rank < 2; rank++ {
		f.read(t, rank, protocol.TypeNativePairCancel)
	}
	select {
	case <-s.writersStopped:
	case <-time.After(2 * time.Second):
		t.Fatal("original relay workers not joined")
	}
	for rank := 0; rank < 2; rank++ {
		receipt := nativePairReleaseReceipt(s.starts[rank])
		if err := f.c.Handle(f.n[rank], appPairMessage(t, f, s, rank, protocol.TypeNativePairOwnerReleased, receipt)); err != nil {
			t.Fatal(err)
		}
		if rank == 0 && f.phase(s) != VerifiedPairQuarantined {
			t.Fatal("one signed release freed pair")
		}
	}
	if f.phase(s) != VerifiedPairReleased {
		t.Fatal("original typed signed cleanup did not release")
	}
}
func TestNativePairAppAttestControlRejectsWrongSignerConnectionReplayAndProof(t *testing.T) {
	for _, kind := range []string{"signer", "connection", "replay", "proof"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativePairFixture(t)
			pairTestAppAttest(t, f.r, f.p[0], "machine-a")
			pairTestAppAttest(t, f.r, f.p[1], "machine-b")
			s := f.reserve(t)
			b, _ := s.starts[0].Canonical()
			m := appPairMessage(t, f, s, 0, protocol.TypeNativePairPrepared, b)
			n := f.n[0]
			switch kind {
			case "signer":
				signed, _ := m.SigningBytes()
				m.Signature = appPairSign(t, 1, signed)
			case "connection":
				n = f.n[1]
			case "replay":
				if err := f.c.Handle(n, m); err != nil {
					t.Fatal(err)
				}
			case "proof":
				f.p[0].mu.Lock()
				f.p[0].appAttestAuthorization.ProofSessionID = "replacement"
				f.p[0].mu.Unlock()
			}
			if err := f.c.Handle(n, m); err == nil {
				t.Fatal("substituted control admitted")
			}
			if f.phase(s) != VerifiedPairReleased {
				t.Fatal("refusal retained or started pending owner")
			}
		})
	}
}
func TestNativePairAppAttestIntentRequiresSelectedActualSigner(t *testing.T) {
	f := newNativePairFixture(t)
	pairTestAppAttest(t, f.r, f.p[0], "machine-a")
	pairTestAppAttest(t, f.r, f.p[1], "machine-b")
	follower := appPairIntent(t, f, 1)
	leader := appPairIntent(t, f, 0)
	b, err := leader.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	leader.Signature = appPairSign(t, 1, b)
	if err = f.c.Configure(f.n[1], follower); err != nil {
		t.Fatal(err)
	}
	if err = f.c.Configure(f.n[0], leader); err != nil {
		t.Fatal(err)
	}
	f.c.mu.Lock()
	record := f.n[0].configuration
	f.c.mu.Unlock()
	if _, _, ok := f.c.configuredSelection(f.n[0], record); ok {
		t.Fatal("claimed identity replaced verified signer")
	}
	requireNoConfiguredHold(t, f)
	raw, _ := base64.StdEncoding.DecodeString(leader.Payload)
	if len(raw) == 0 {
		t.Fatal("fixture omitted configured consent")
	}
}
