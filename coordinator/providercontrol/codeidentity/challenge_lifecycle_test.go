package codeidentity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestCodeIdentityRoundTripEndToEnd is the correctness gate: the full crypto
// round-trip — coordinator generates a nonce → real E_K(nonce) encrypt → genuine-
// provider decrypt with K → Sign_SE over the recovered nonce → WS reply verified
// in the read-loop delivery path → CodeAttested flips true.
func TestCodeIdentityRoundTripEndToEnd(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a valid end-to-end round-trip")
	}
}

// TestCodeIdentityRejectsWrongSEKey proves fail-closed: a response whose nonce
// decrypts correctly (proving K) but is signed by a DIFFERENT SE key (not the one
// bound at registration) must NOT attest — defending against a fork that received
// a relayed challenge but holds its own SE key.
func TestCodeIdentityRejectsWrongSEKey(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)

	kPubB64, kPriv, _, sePubB64 := providerKeyMaterial(t)
	wrongSE, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen wrong SE: %v", err)
	}
	provider := newCodeAttestProvider(kPubB64, sePubB64) // bound to the REAL SE key

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		// Decrypts fine (proves K), but signs with the WRONG SE key.
		return completeRoundTrip(t, srv, provider, "p1", kPriv, wrongSE, pubKeyB64, nonceB64)
	}})

	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)

	if provider.GetCodeAttested() {
		t.Fatal("CodeAttested must stay false when the SE signature is from the wrong key")
	}
}

// TestCodeAttestLoopHealsDroppedPushWithBoundedRetry proves a single dropped push
// doesn't strand a capable provider: the first push fails and the loop retries.
func TestCodeAttestLoopHealsDroppedPushWithBoundedRetry(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)
	srv.state.backgroundPushCooldown = time.Millisecond // fast budget for the test
	srv.state.retrySpacing = time.Millisecond           // fast poll cadence
	srv.state.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		if atomic.AddInt32(&pushes, 1) == 1 {
			return errors.New("transient push send failure") // first push fails
		}
		return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
	}})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.Loop(ctx, "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("expected CodeAttested=true after a bounded retry healed the dropped first push")
	}
	if got := atomic.LoadInt32(&pushes); got < 2 || got > int32(srv.state.maxAttempts) {
		t.Fatalf("expected 2..%d pushes, got %d", srv.state.maxAttempts, got)
	}
}

// TestCodeAttestLoopReusesRecentAttestation proves same-version reuse is limited
// to the exact process key that completed the prior proof: a same-key reconnect
// spends no APNs push, while K2 gets no code trust until one fresh challenge.
func TestCodeAttestLoopReusesRecentAttestation(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := newTestManager(registry.New(logger), st, testServerConfig{}, logger)
	srv.state.retrySpacing = time.Millisecond
	srv.state.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	expectUntrustedAtFreshProcessPush := false
	// onSend completes the round-trip for whichever provider is currently attesting.
	var current *registry.Provider
	currentPriv := kPriv
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pubKeyB64, nonceB64 string) error {
		if expectUntrustedAtFreshProcessPush &&
			(current.GetCodeAttested() || current.GetFreshCodeAttested()) {
			t.Fatal("K2 inherited K1 code trust before its fresh APNs proof")
		}
		atomic.AddInt32(&pushes, 1)
		return completeRoundTrip(t, srv, current, "p1", currentPriv, seKey, pubKeyB64, nonceB64)
	}})
	srv.codeResumeSender = func(
		_ string,
		message protocol.CodeAttestationResumeChallenge,
	) error {
		if current.GetCodeAttested() || current.GetFreshCodeAttested() {
			t.Fatal("cached APNs evidence granted code trust before live process-key proof")
		}
		recovered, err := e2e.DecryptWithPrivateKey(
			&e2e.EncryptedPayload{
				EphemeralPublicKey: message.CodeChallenge.EphemeralPublicKey,
				Ciphertext:         message.CodeChallenge.Ciphertext,
			},
			currentPriv,
		)
		if err != nil {
			return err
		}
		nonce := string(recovered)
		srv.HandleResponse(
			"p1",
			current,
			&protocol.CodeAttestationResponseMessage{
				Type:      protocol.TypeCodeAttestationResponse,
				Nonce:     nonce,
				Signature: signSEOverString(t, seKey, nonce),
			},
		)
		return nil
	}

	// Connection 1: a real round-trip → exactly one push, attested.
	p1 := newCodeAttestProvider(kPubB64, sePubB64)
	p1.Version = "0.6.0"
	current = p1
	srv.Loop(context.Background(), "p1", p1)
	if !p1.GetCodeAttested() {
		t.Fatal("connection 1 should attest")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("connection 1 should send exactly 1 push, got %d", got)
	}

	// Connection 2: same device + version, fresh Provider (CodeAttested=false). It
	// must REUSE the recent attestation — attested without another push.
	p2 := newCodeAttestProvider(kPubB64, sePubB64)
	p2.Version = "0.6.0"
	current = p2
	srv.Loop(context.Background(), "p1", p2)
	if !p2.GetCodeAttested() {
		t.Fatal("connection 2 should inherit the recent attestation (reuse)")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("connection 2 must NOT send another push (reuse); total pushes=%d", got)
	}

	// Connection 3 advertises protected runtime capabilities but retains the
	// exact process X25519 key. It reuses the process-bound proof without
	// spending another throttled push.
	p3 := newCodeAttestProvider(kPubB64, sePubB64)
	p3.Version = "0.6.0"
	p3.ReportedRuntimeCapabilities = []string{
		registry.ProviderCapabilityAppleM5,
		registry.ProviderCapabilityMLXNAX,
	}
	current = p3
	srv.Loop(context.Background(), "p1", p3)
	if !p3.GetCodeAttested() || !p3.GetFreshCodeAttested() {
		t.Fatal("same-process protected reconnect should reuse bound proof")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("same-process reconnect unexpectedly pushed; total=%d", got)
	}
	kPubB64New, kPrivNew, _, _ := providerKeyMaterial(t)
	copiedPublic := newCodeAttestProvider(kPubB64, sePubB64)
	copiedPublic.Version = "0.6.0"
	copiedPublic.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = copiedPublic, kPrivNew
	if srv.sendCodeIdentityResumeChallenge(
		context.Background(), "p1", copiedPublic, kPubB64, sePubB64,
		copiedPublic.APNsDeviceToken,
	) || copiedPublic.GetFreshCodeAttested() {
		t.Fatal("copied public key without old X25519 private key passed resume PoP")
	}

	// Same-version K2 on the same SE device/token cannot reuse K1's proof. It
	// remains untrusted until exactly one fresh E_K2(nonce)+SE challenge completes.
	p4 := newCodeAttestProvider(kPubB64New, sePubB64)
	p4.Version = "0.6.0"
	p4.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p4, kPrivNew
	srv.state.backgroundPushCooldown = 0
	// Simulate expiry of Apple's existing per-token push window without
	// weakening production A-B-A cooldown retention.
	budgetKey := codeAttestPushBudgetKey(
		sePubB64, codeAttestTokenHash(p4.APNsDeviceToken),
	)
	srv.state.mu.Lock()
	delete(srv.state.lastPush, budgetKey)
	delete(srv.state.durableNextPush, budgetKey)
	delete(srv.state.novelPushFloor, sePubB64)
	srv.state.mu.Unlock()
	if err := st.DeleteCodeAttestPushBudget(
		context.Background(), sePubB64,
	); err != nil {
		t.Fatalf("fresh process test could not expire durable cooldown: %v", err)
	}
	expectUntrustedAtFreshProcessPush = true
	srv.Loop(context.Background(), "p1", p4)
	expectUntrustedAtFreshProcessPush = false
	if !p4.GetCodeAttested() || !p4.GetFreshCodeAttested() {
		t.Fatal("K2 should complete code trust only after its fresh proof")
	}
	if got := atomic.LoadInt32(&pushes); got != 2 {
		t.Fatalf("K2 should force exactly one fresh APNs challenge; total pushes=%d", got)
	}

	// Same-process resume that gets no reply falls back to APNs on this live
	// connection after the bounded timeout. A late resume reply cannot replay.
	var timedOutResumeNonce string
	srv.state.resumeTimeout = time.Millisecond
	srv.state.retrySpacing = time.Millisecond
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		recovered, err := e2e.DecryptWithPrivateKey(
			&e2e.EncryptedPayload{
				EphemeralPublicKey: message.CodeChallenge.EphemeralPublicKey,
				Ciphertext:         message.CodeChallenge.Ciphertext,
			},
			kPrivNew,
		)
		timedOutResumeNonce = string(recovered)
		return err
	}
	p5 := newCodeAttestProvider(kPubB64New, sePubB64)
	p5.Version = "0.6.0"
	p5.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p5, kPrivNew
	srv.Loop(context.Background(), "p1", p5)
	deadline := time.Now().Add(time.Second)
	for !p5.GetFreshCodeAttested() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !p5.GetFreshCodeAttested() || atomic.LoadInt32(&pushes) != 3 {
		t.Fatalf("resume timeout did not APNs-fallback: fresh=%v pushes=%d",
			p5.GetFreshCodeAttested(), atomic.LoadInt32(&pushes))
	}
	srv.HandleResponse("p1", p5, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     timedOutResumeNonce,
		Signature: signSEOverString(t, seKey, timedOutResumeNonce),
	})
	if got := atomic.LoadInt32(&pushes); got != 3 {
		t.Fatalf("late resume reply changed fallback state: pushes=%d", got)
	}

	// A resume transport failure falls through to APNs immediately.
	srv.codeResumeSender = func(
		string, protocol.CodeAttestationResumeChallenge,
	) error {
		return errors.New("resume send failed")
	}
	p6 := newCodeAttestProvider(kPubB64New, sePubB64)
	p6.Version = "0.6.0"
	p6.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p6, kPrivNew
	srv.Loop(context.Background(), "p1", p6)
	if !p6.GetFreshCodeAttested() || atomic.LoadInt32(&pushes) != 4 {
		t.Fatalf("resume send failure did not immediately fall back: fresh=%v pushes=%d",
			p6.GetFreshCodeAttested(), atomic.LoadInt32(&pushes))
	}

	// Cancellation after the timer consumes the resume nonce but before fallback
	// must not send or charge APNs on behalf of a dead connection.
	srv.codeResumeSender = func(
		string, protocol.CodeAttestationResumeChallenge,
	) error {
		return nil // no response; let the resume timer win
	}
	resumeCtx, cancelResume := context.WithCancel(context.Background())
	fallbackReached := make(chan struct{})
	srv.codeResumeFallbackBeforeAPNs = func() {
		cancelResume()
		close(fallbackReached)
	}
	srv.state.mu.Lock()
	lastPushBefore := srv.state.lastPush[sePubB64]
	srv.state.mu.Unlock()
	p7 := newCodeAttestProvider(kPubB64New, sePubB64)
	p7.Version = "0.6.0"
	p7.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p7, kPrivNew
	srv.Loop(resumeCtx, "p1", p7)
	select {
	case <-fallbackReached:
	case <-time.After(time.Second):
		t.Fatal("resume timeout did not reach cancellation seam")
	}
	time.Sleep(10 * time.Millisecond)
	srv.state.mu.Lock()
	lastPushAfter := srv.state.lastPush[sePubB64]
	srv.state.mu.Unlock()
	if got := atomic.LoadInt32(&pushes); got != 4 ||
		!lastPushAfter.Equal(lastPushBefore) ||
		p7.GetFreshCodeAttested() {
		t.Fatalf("canceled fallback spent APNs budget: pushes=%d before=%v after=%v fresh=%v",
			got, lastPushBefore, lastPushAfter, p7.GetFreshCodeAttested())
	}

	// Cancellation inside the resume write failure must also stop before APNs.
	srv.codeResumeFallbackBeforeAPNs = nil
	writeCtx, cancelWrite := context.WithCancel(context.Background())
	srv.codeResumeSender = func(
		string, protocol.CodeAttestationResumeChallenge,
	) error {
		cancelWrite()
		return errors.New("connection canceled during resume write")
	}
	p8 := newCodeAttestProvider(kPubB64New, sePubB64)
	p8.Version = "0.6.0"
	p8.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p8, kPrivNew
	srv.Loop(writeCtx, "p1", p8)
	srv.state.mu.Lock()
	lastPushAfterWriteCancel := srv.state.lastPush[sePubB64]
	srv.state.mu.Unlock()
	if got := atomic.LoadInt32(&pushes); got != 4 ||
		!lastPushAfterWriteCancel.Equal(lastPushBefore) ||
		p8.GetFreshCodeAttested() {
		t.Fatalf("canceled resume write spent APNs budget: pushes=%d before=%v after=%v fresh=%v",
			got, lastPushBefore, lastPushAfterWriteCancel,
			p8.GetFreshCodeAttested())
	}

	// Token rotation after cache match but before resume creation invalidates the
	// captured loop; the heartbeat rearm's fresh loop earns a new APNs proof.
	p9 := newCodeAttestProvider(kPubB64New, sePubB64)
	p9.Version = "0.6.0"
	p9.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p9, kPrivNew
	srv.codeResumeBeforeIdentityCheck = func() {
		p9.Mu().Lock()
		p9.APNsDeviceToken = "rotated-token"
		p9.Mu().Unlock()
		// Production token rotation synchronously supersedes the old loop before
		// launching its replacement.
		srv.state.beginLoop(sePubB64)
		srv.codeResumeBeforeIdentityCheck = nil
	}
	srv.codeResumeSender = func(
		string, protocol.CodeAttestationResumeChallenge,
	) error {
		return errors.New("resume sender must not run after identity rotation")
	}
	srv.Loop(context.Background(), "p1", p9)
	srv.Loop(context.Background(), "p1", p9)
	if !p9.GetFreshCodeAttested() || atomic.LoadInt32(&pushes) != 5 {
		t.Fatalf("pre-record token rotation did not APNs-fallback: fresh=%v pushes=%d",
			p9.GetFreshCodeAttested(), atomic.LoadInt32(&pushes))
	}

	// Rotation after the resume was sent clears that one-time proof and arms a
	// fresh APNs loop; the late old-token response cannot grant it.
	p10 := newCodeAttestProvider(kPubB64New, sePubB64)
	p10.Version = "0.6.0"
	p10.APNsDeviceToken = "rotated-token"
	p10.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p10, kPrivNew
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		recovered, err := e2e.DecryptWithPrivateKey(
			&e2e.EncryptedPayload{
				EphemeralPublicKey: message.CodeChallenge.EphemeralPublicKey,
				Ciphertext:         message.CodeChallenge.Ciphertext,
			},
			kPrivNew,
		)
		if err != nil {
			return err
		}
		srv.Rearm(
			context.Background(), "p1", p10,
			&protocol.HeartbeatMessage{APNsDeviceToken: "rotated-again"},
		)
		nonce := string(recovered)
		srv.HandleResponse(
			"p1", p10, &protocol.CodeAttestationResponseMessage{
				Type:      protocol.TypeCodeAttestationResponse,
				Nonce:     nonce,
				Signature: signSEOverString(t, seKey, nonce),
			},
		)
		return nil
	}
	srv.Loop(context.Background(), "p1", p10)
	deadline = time.Now().Add(time.Second)
	for !p10.GetFreshCodeAttested() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !p10.GetFreshCodeAttested() || atomic.LoadInt32(&pushes) != 6 {
		t.Fatalf("pre-response token rotation did not APNs-fallback: fresh=%v pushes=%d",
			p10.GetFreshCodeAttested(), atomic.LoadInt32(&pushes))
	}

	// A malformed SE signature does not consume/cancel the resume challenge;
	// its timer remains armed and falls back to fresh APNs.
	p11 := newCodeAttestProvider(kPubB64New, sePubB64)
	p11.Version = "0.6.0"
	p11.APNsDeviceToken = "rotated-again"
	p11.ReportedRuntimeCapabilities = p3.ReportedRuntimeCapabilities
	current, currentPriv = p11, kPrivNew
	srv.codeResumeSender = func(
		_ string, message protocol.CodeAttestationResumeChallenge,
	) error {
		recovered, err := e2e.DecryptWithPrivateKey(
			&e2e.EncryptedPayload{
				EphemeralPublicKey: message.CodeChallenge.EphemeralPublicKey,
				Ciphertext:         message.CodeChallenge.Ciphertext,
			},
			kPrivNew,
		)
		if err != nil {
			return err
		}
		srv.HandleResponse(
			"p1", p11, &protocol.CodeAttestationResponseMessage{
				Type:      protocol.TypeCodeAttestationResponse,
				Nonce:     string(recovered),
				Signature: base64.StdEncoding.EncodeToString([]byte("bad")),
			},
		)
		return nil
	}
	srv.Loop(context.Background(), "p1", p11)
	deadline = time.Now().Add(time.Second)
	for !p11.GetFreshCodeAttested() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !p11.GetFreshCodeAttested() || atomic.LoadInt32(&pushes) != 7 {
		t.Fatalf("invalid resume signature did not APNs-fallback: fresh=%v pushes=%d",
			p11.GetFreshCodeAttested(), atomic.LoadInt32(&pushes))
	}
}

// TestCodeAttestLateReplyOnLiveConnectionStillAttests proves Fix 1 + Fix 5: a
// reply arriving long after the old 90s blocking wait — but on a live connection
// and within the (widened) challenge validity window — still attests, because
// verification now happens in the read-loop delivery path rather than a goroutine
// that times out at 90s. The complementary case proves the validity bound stays
// fail-closed: a reply past the window is rejected.
func TestCodeAttestLateReplyOnLiveConnectionStillAttests(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)

	cur := time.Unix(1_700_000_000, 0)
	srv.state.now = func() time.Time { return cur }

	kPubB64, _, seKey, sePubB64 := providerKeyMaterial(t)

	// Capture the pushed nonce; do NOT deliver during the push (model a sleepy
	// device that answers later).
	var pushedNonce string
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, nonceB64 string) error {
		pushedNonce = nonceB64
		return nil
	}})

	// Case A: reply 91s later (was > the old 90s wait) but inside the 300s window.
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "p1", provider)
	if provider.GetCodeAttested() {
		t.Fatal("must not attest before any reply arrives")
	}
	cur = cur.Add(91 * time.Second)
	srv.HandleResponse("p1", provider, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})
	if !provider.GetCodeAttested() {
		t.Fatal("a reply 91s later on a live connection must still attest (Fix 1 + Fix 5)")
	}

	// Case B: a reply past the validity window must be rejected (fail-closed).
	cur = cur.Add(time.Hour)
	late := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "p1", late)
	cur = cur.Add(srv.state.challengeValidity + time.Second)
	srv.HandleResponse("p1", late, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})
	if late.GetCodeAttested() {
		t.Fatal("a reply past the challenge validity window must not attest (fail-closed staleness)")
	}
}

// TestCodeAttestReconnectMidFlightDoesNotStrand proves Fix 1 kills the connection-
// scoped strand: a challenge pushed on connection 1 is verified when its reply
// lands on connection 2 (a reconnect from the SAME device), with NO second push —
// because the pushed nonce is tracked per-device (by SE key), not per-connection.
func TestCodeAttestReconnectMidFlightDoesNotStrand(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)

	kPubB64, _, seKey, sePubB64 := providerKeyMaterial(t)

	var pushes int32
	var pushedNonce string
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, nonceB64 string) error {
		atomic.AddInt32(&pushes, 1)
		pushedNonce = nonceB64 // push goes out, but conn 1 drops before replying
		return nil
	}})

	// Connection 1 pushes a challenge, then "drops" before the reply.
	conn1 := newCodeAttestProvider(kPubB64, sePubB64)
	srv.sendCodeIdentityChallenge(context.Background(), "conn1", conn1)
	if conn1.GetCodeAttested() {
		t.Fatal("conn1 must not be attested (it dropped before replying)")
	}

	// A different process key K2 on the same SE device/token cannot consume K1's
	// challenge or inherit its proof.
	kPubB64New, _, _, _ := providerKeyMaterial(t)
	wrongProcess := newCodeAttestProvider(kPubB64New, sePubB64)
	srv.HandleResponse(
		"conn2-wrong",
		wrongProcess,
		&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     pushedNonce,
			Signature: signSEOverString(t, seKey, pushedNonce),
		},
	)
	if wrongProcess.GetCodeAttested() {
		t.Fatal("K2 consumed an APNs challenge encrypted to K1")
	}

	// Connection 2 is a fresh connection from the SAME device (same SE key). The
	// provider's reply to conn1's challenge now lands here.
	conn2 := newCodeAttestProvider(kPubB64, sePubB64)
	srv.HandleResponse("conn2", conn2, &protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     pushedNonce,
		Signature: signSEOverString(t, seKey, pushedNonce),
	})

	if !conn2.GetCodeAttested() {
		t.Fatal("a reply on a reconnected socket must attest the live connection (no strand)")
	}
	if got := atomic.LoadInt32(&pushes); got != 1 {
		t.Fatalf("reconnect must NOT burn another push; pushes=%d", got)
	}

	// K2 becomes eligible only after its own freshly encrypted APNs challenge.
	srv.sendCodeIdentityChallenge(context.Background(), "conn2-wrong", wrongProcess)
	srv.HandleResponse(
		"conn2-wrong",
		wrongProcess,
		&protocol.CodeAttestationResponseMessage{
			Type:      protocol.TypeCodeAttestationResponse,
			Nonce:     pushedNonce,
			Signature: signSEOverString(t, seKey, pushedNonce),
		},
	)
	if !wrongProcess.GetCodeAttested() {
		t.Fatal("K2 did not attest after its own fresh APNs challenge")
	}
	if got := atomic.LoadInt32(&pushes); got != 2 {
		t.Fatalf("fresh K2 challenge push count=%d, want 2", got)
	}
}

// TestCodeAttestNoTokenNeverAttests is the fail-closed gate for a provider with no
// APNs device token (legacy/headless): the loop exits immediately, never pushes,
// and the connection never attests.
func TestCodeAttestNoTokenNeverAttests(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)
	provider.APNsDeviceToken = "" // no token → cannot be challenged

	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		t.Fatal("must not push when the provider has no APNs token")
		return nil
	}})

	srv.Loop(context.Background(), "p1", provider)
	if provider.GetCodeAttested() {
		t.Fatal("a provider with no APNs token must never attest (fail-closed)")
	}
}

// TestCodeAttestTimeoutNeverAttests is the fail-closed gate for a delivered push
// that is never answered: the loop pushes up to maxAttempts and gives up without
// attesting.
func TestCodeAttestTimeoutNeverAttests(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)
	srv.state.maxAttempts = 2
	srv.state.backgroundPushCooldown = time.Millisecond
	srv.state.retrySpacing = time.Millisecond
	srv.state.retryJitter = 0

	kPubB64, _, _, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		atomic.AddInt32(&pushes, 1) // push accepted, but the provider never replies
		return nil
	}})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.Loop(ctx, "p1", provider)

	if provider.GetCodeAttested() {
		t.Fatal("an unanswered challenge must never attest (fail-closed)")
	}
	if got := atomic.LoadInt32(&pushes); got != int32(srv.state.maxAttempts) {
		t.Fatalf("expected exactly maxAttempts=%d pushes, got %d", srv.state.maxAttempts, got)
	}
}

// TestCodeAttestLoopAlertModeUsesShortBudget proves Fix 3: in alert mode the loop
// retries on the (short) alert push budget, not the (long) background budget. The
// background budget is set to an hour and the alert budget to ~nothing; if the loop
// used the background budget it could never heal the dropped first push within the
// test deadline.
func TestCodeAttestLoopAlertModeUsesShortBudget(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), testServerConfig{}, logger)
	srv.state.alertPushCooldown = time.Millisecond
	srv.state.backgroundPushCooldown = time.Hour // would strand if used
	srv.state.retrySpacing = time.Millisecond
	srv.state.retryJitter = 0

	kPubB64, kPriv, seKey, sePubB64 := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPubB64, sePubB64)

	var pushes int32
	srv.SetCodeAttestor(&fakeCodeAttestor{
		mode: apns.ModeAlert,
		onSend: func(_, _, pubKeyB64, nonceB64 string) error {
			if atomic.AddInt32(&pushes, 1) == 1 {
				return errors.New("transient push send failure") // first push fails
			}
			return completeRoundTrip(t, srv, provider, "p1", kPriv, seKey, pubKeyB64, nonceB64)
		},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	srv.Loop(ctx, "p1", provider)

	if !provider.GetCodeAttested() {
		t.Fatal("alert mode must retry on the short alert budget and heal within the deadline")
	}
}
