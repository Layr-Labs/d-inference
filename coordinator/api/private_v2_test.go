package api

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

func testPrivateV2Lease(id, request, consumer, provider string, expires time.Time) *privateV2Lease {
	return &privateV2Lease{ConsumerHash: privateV2ConsumerHash(consumer),
		Provider:   registry.PrivateV2ProviderSnapshot{ProviderID: provider},
		Transcript: privateV2Transcript{LeaseID: id, RequestID: request}, ExpiresAt: expires}
}

func TestPrivateV2LeaseOneUseConcurrent(t *testing.T) {
	manager := newPrivateV2LeaseManager(8)
	now := time.Unix(100, 0)
	manager.now = func() time.Time { return now }
	if err := manager.put(testPrivateV2Lease("lease", "request", "consumer", "provider", now.Add(time.Minute))); err != nil {
		t.Fatal(err)
	}
	var successes atomic.Int32
	var wait sync.WaitGroup
	for range 32 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if _, err := manager.consume("lease", "request", "consumer"); err == nil {
				successes.Add(1)
			}
		}()
	}
	wait.Wait()
	if successes.Load() != 1 {
		t.Fatalf("successful consumes = %d, want 1", successes.Load())
	}
}

func TestPrivateV2LeaseExpiryMismatchInvalidationAndCapacity(t *testing.T) {
	now := time.Unix(200, 0)
	manager := newPrivateV2LeaseManager(2)
	manager.now = func() time.Time { return now }
	if err := manager.put(testPrivateV2Lease("expired", "r0", "c", "p0", now)); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.consume("expired", "r0", "c"); err != errPrivateV2LeaseExpired {
		t.Fatalf("expired consume error = %v", err)
	}
	if err := manager.put(testPrivateV2Lease("a", "ra", "consumer-a", "provider-a", now.Add(time.Minute))); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.consume("a", "ra", "consumer-b"); err != errPrivateV2LeaseConsumer {
		t.Fatalf("consumer mismatch error = %v", err)
	}
	if _, err := manager.consume("a", "wrong", "consumer-a"); err != errPrivateV2RequestID {
		t.Fatalf("request mismatch error = %v", err)
	}
	if err := manager.put(testPrivateV2Lease("b", "rb", "consumer-b", "provider-b", now.Add(time.Minute))); err != nil {
		t.Fatal(err)
	}
	if err := manager.put(testPrivateV2Lease("full", "rf", "c", "p", now.Add(time.Minute))); err != errPrivateV2LeaseCapacity {
		t.Fatalf("capacity error = %v", err)
	}
	manager.invalidateProvider("provider-a")
	if _, err := manager.consume("a", "ra", "consumer-a"); err != errPrivateV2LeaseNotFound {
		t.Fatalf("invalidated consume error = %v", err)
	}
	if _, err := manager.consume("b", "rb", "consumer-b"); err != nil {
		t.Fatalf("unrelated provider lease was invalidated: %v", err)
	}
}

func TestPrivateV2LeasePerConsumerFairnessCap(t *testing.T) {
	manager := newPrivateV2LeaseManager(32)
	now := time.Unix(300, 0)
	manager.now = func() time.Time { return now }
	for i := range privateV2PerConsumerLeases {
		id := fmt.Sprintf("same-%d", i)
		if err := manager.put(testPrivateV2Lease(id, id, "same-consumer", "provider", now.Add(time.Minute))); err != nil {
			t.Fatalf("lease %d: %v", i, err)
		}
	}
	if err := manager.put(testPrivateV2Lease("same-over", "same-over", "same-consumer", "provider", now.Add(time.Minute))); err != errPrivateV2LeaseCapacity {
		t.Fatalf("same-consumer overflow = %v", err)
	}
	if err := manager.put(testPrivateV2Lease("other", "other", "other-consumer", "provider", now.Add(time.Minute))); err != nil {
		t.Fatalf("fair slot for other consumer rejected: %v", err)
	}
}

func TestPrivateV2SequenceLedgerBoundsChunksAndBytes(t *testing.T) {
	request := &registry.PendingRequest{}
	for i := range privateV2MaxResponseChunks {
		sequence := uint64(i)
		if !request.AcceptPrivateV2Sequence(protocol.PrivateChunkV2Message{Sequence: sequence}, 16) {
			t.Fatalf("sequence %d rejected before cap", sequence)
		}
	}
	if request.AcceptPrivateV2Sequence(protocol.PrivateChunkV2Message{Sequence: uint64(privateV2MaxResponseChunks)}, 16) {
		t.Fatal("sequence above 8192-entry cap accepted")
	}
	bytesRequest := &registry.PendingRequest{}
	if !bytesRequest.AcceptPrivateV2Sequence(protocol.PrivateChunkV2Message{Sequence: 0}, privateV2MaxResponseBytes) {
		t.Fatal("response at decoded-byte cap rejected")
	}
	if bytesRequest.AcceptPrivateV2Sequence(protocol.PrivateChunkV2Message{Sequence: 1}, 16) {
		t.Fatal("response above decoded-byte cap accepted")
	}
}

func TestPrivateV2UsageCannotExceedAuthenticatedAdmission(t *testing.T) {
	request := &registry.PendingRequest{
		PrivateV2PromptTokenBound: 100,
		PrivateV2OutputTokenBound: 40,
		TokenAdmission:            registry.TokenAdmission{AdmittedOutputTokens: 30},
	}
	if !validPrivateV2Usage(request, &protocol.PrivateUsageV2{
		PromptTokens: 100, CompletionTokens: 30, TotalTokens: 130,
	}) {
		t.Fatal("usage at every authenticated bound rejected")
	}
	for name, usage := range map[string]*protocol.PrivateUsageV2{
		"prompt":    {PromptTokens: 101, CompletionTokens: 1, TotalTokens: 102},
		"output":    {PromptTokens: 1, CompletionTokens: 41, TotalTokens: 42},
		"admission": {PromptTokens: 1, CompletionTokens: 31, TotalTokens: 32},
		"total":     {PromptTokens: 1, CompletionTokens: 1, TotalTokens: 3},
	} {
		if validPrivateV2Usage(request, usage) {
			t.Fatalf("%s violation accepted", name)
		}
	}
}

func TestPrivateV2MaxOutputTokenBoundary(t *testing.T) {
	if !validPrivateV2MaxOutputTokens(int(protocol.PrivateV2MaxOutputTokens)) {
		t.Fatal("shared 8000-token maximum was rejected")
	}
	if validPrivateV2MaxOutputTokens(int(protocol.PrivateV2MaxOutputTokens) + 1) {
		t.Fatal("output maximum above 8000 was accepted")
	}
}

func TestPrivateV2RouteBindingNeverExposesOwnerIdentity(t *testing.T) {
	const owner = "account-secret-owner"
	mode, binding := privateV2RouteBinding(selfRoutePolicy{enabled: true, ownerAccountID: owner})
	wantHash := privateV2ConsumerHash(owner)
	if mode != "self_route_only" || binding != base64.RawURLEncoding.EncodeToString(wantHash[:]) ||
		strings.Contains(binding, owner) {
		t.Fatalf("unsafe self-route binding mode=%q binding=%q", mode, binding)
	}
	if mode, binding := privateV2RouteBinding(selfRoutePolicy{}); mode != "public" || binding != "" {
		t.Fatalf("public route binding = %q %q", mode, binding)
	}
}

func TestPrivateV2SequenceAndOpaqueCiphertext(t *testing.T) {
	request := &registry.PendingRequest{}
	sentinel := base64.RawURLEncoding.EncodeToString([]byte("PLAINTEXT-SENTINEL"))
	first := protocol.PrivateChunkV2Message{Sequence: 0, Nonce: "nonce", Ciphertext: sentinel}
	if !request.AcceptPrivateV2Sequence(first, 16) {
		t.Fatal("sequence 0 rejected")
	}
	if first.Ciphertext != sentinel {
		t.Fatal("opaque ciphertext changed")
	}
	if request.AcceptPrivateV2Sequence(first, 16) {
		t.Fatal("replayed sequence accepted")
	}
	terminal := protocol.PrivateChunkV2Message{Sequence: 1, Terminal: true, Nonce: "nonce2", Ciphertext: "tampered-ciphertext"}
	if !request.AcceptPrivateV2Sequence(terminal, 16) {
		t.Fatal("ordered terminal rejected")
	}
	if terminal.Ciphertext != "tampered-ciphertext" {
		t.Fatal("tampered ciphertext was not passed through unchanged")
	}
	if request.AcceptPrivateV2Sequence(protocol.PrivateChunkV2Message{Sequence: 2}, 16) {
		t.Fatal("post-terminal chunk accepted")
	}
}

func TestPrivateV2NonStreamRelaysOrderedOpaqueChunks(t *testing.T) {
	chunks := make(chan protocol.PrivateChunkV2Message, 2)
	chunks <- protocol.PrivateChunkV2Message{
		Type: protocol.TypePrivateChunkV2, Version: privateV2Version,
		RequestID: "request", Sequence: 0, Nonce: "nonce-0", Ciphertext: "opaque-0",
	}
	chunks <- protocol.PrivateChunkV2Message{
		Type: protocol.TypePrivateChunkV2, Version: privateV2Version,
		RequestID: "request", Sequence: 1, Terminal: true,
		Nonce: "nonce-1", Ciphertext: "opaque-tampered-1",
		Usage: &protocol.PrivateUsageV2{PromptTokens: 3, CompletionTokens: 4, TotalTokens: 7},
	}
	request := &registry.PendingRequest{RequestID: "request", PrivateV2ChunkCh: chunks}
	response := httptest.NewRecorder()
	(&Server{}).relayPrivateV2NonStream(response,
		httptest.NewRequest(http.MethodPost, "/v1/private/requests", nil), nil, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", response.Code, response.Body.String())
	}
	var decoded privateV2NonStreamResponse
	if err := json.Unmarshal(response.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Version != privateV2Version || decoded.RequestID != "request" ||
		len(decoded.Chunks) != 2 || decoded.Chunks[0].Sequence != 0 ||
		decoded.Chunks[1].Sequence != 1 || !decoded.Chunks[1].Terminal ||
		decoded.Chunks[0].Ciphertext != "opaque-0" ||
		decoded.Chunks[1].Ciphertext != "opaque-tampered-1" {
		t.Fatalf("opaque relay changed chunks: %+v", decoded)
	}
	if !request.ContentCommittedSafe() {
		t.Fatal("successful nonstream encrypted response was not marked committed")
	}
}

func TestPrivateV2DeliveryGateReleasesSettlementOnce(t *testing.T) {
	request := &registry.PendingRequest{PrivateV2DeliveryCh: make(chan struct{})}
	done := make(chan struct{})
	go func() {
		request.AwaitPrivateV2Delivery()
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("settlement passed before delivery resolved")
	default:
	}
	request.ResolvePrivateV2Delivery()
	request.ResolvePrivateV2Delivery()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("settlement did not resume after delivery resolution")
	}
}

func TestPrivateV2CommittedRelayOverflowParksWithoutRefund(t *testing.T) {
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{})
	request := &registry.PendingRequest{
		RequestID: "overflow", Model: "model", ProviderID: provider.ID,
		PrivateV2ChunkCh:   make(chan protocol.PrivateChunkV2Message, privateV2ChunkBuffer),
		PrivateV2SettledCh: make(chan struct{}), PrivateV2DeliveryCh: make(chan struct{}),
		PrivateV2PromptTokenBound: 100, PrivateV2OutputTokenBound: 100,
	}
	request.MarkContentCommitted()
	request.ResolvePrivateV2Delivery()
	for range privateV2ChunkBuffer {
		request.PrivateV2ChunkCh <- protocol.PrivateChunkV2Message{}
	}
	provider.AddPending(request)
	server := &Server{
		registry: reg, settlements: newSettlementHolder(),
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	nonce := base64.RawURLEncoding.EncodeToString(make([]byte, 12))
	ciphertext := base64.RawURLEncoding.EncodeToString(make([]byte, 16))
	server.handlePrivateV2Chunk(provider.ID, provider, &protocol.PrivateChunkV2Message{
		Type: protocol.TypePrivateChunkV2, Version: privateV2Version,
		RequestID: request.RequestID, Sequence: 0, Nonce: nonce, Ciphertext: ciphertext,
	})
	if provider.GetPending(request.RequestID) != nil {
		t.Fatal("committed overflow retained provider pending request")
	}
	if parked := server.claimSettlement(request.RequestID); parked != request {
		t.Fatal("committed overflow was not parked for terminal settlement")
	}
	if request.IsReservationFinalized() {
		t.Fatal("committed overflow finalized an early refund")
	}
}

func TestPrivateV2MalformedParkedTerminalAlwaysSignalsSettlement(t *testing.T) {
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("provider", nil, &protocol.RegisterMessage{})
	request := &registry.PendingRequest{
		RequestID: "parked-malformed", Model: "model", ProviderID: provider.ID,
		PrivateV2ChunkCh:   make(chan protocol.PrivateChunkV2Message, 1),
		PrivateV2SettledCh: make(chan struct{}), PrivateV2DeliveryCh: make(chan struct{}),
		PrivateV2PromptTokenBound: 100, PrivateV2OutputTokenBound: 100,
	}
	request.MarkContentCommitted()
	request.ResolvePrivateV2Delivery()
	server := &Server{
		registry: reg, settlements: newSettlementHolder(),
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	server.settlements.hold(request, time.Minute, func(*registry.PendingRequest) {})
	server.handlePrivateV2Chunk(provider.ID, provider, &protocol.PrivateChunkV2Message{
		Type: protocol.TypePrivateChunkV2, Version: privateV2Version,
		RequestID: request.RequestID, Sequence: 0, Terminal: true,
		Nonce: "malformed", Ciphertext: "malformed",
	})
	select {
	case <-request.PrivateV2SettledCh:
	default:
		t.Fatal("malformed parked terminal did not release settlement waiter")
	}
}

func TestPrivateV2InvalidCommittedChunkAlwaysSignalsSettlement(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	provider := reg.Register("active-invalid", nil, &protocol.RegisterMessage{})
	request := &registry.PendingRequest{
		RequestID: "active-invalid", Model: "model", ProviderID: provider.ID,
		PrivateV2ChunkCh:   make(chan protocol.PrivateChunkV2Message, 1),
		PrivateV2SettledCh: make(chan struct{}), PrivateV2DeliveryCh: make(chan struct{}),
		PrivateV2PromptTokenBound: 100, PrivateV2OutputTokenBound: 100,
	}
	request.MarkContentCommitted()
	request.ResolvePrivateV2Delivery()
	provider.AddPending(request)
	server := &Server{registry: reg, settlements: newSettlementHolder(), logger: logger}
	server.handlePrivateV2Chunk(provider.ID, provider, &protocol.PrivateChunkV2Message{
		Type: protocol.TypePrivateChunkV2, Version: privateV2Version,
		RequestID: request.RequestID, Sequence: 0, Nonce: "malformed", Ciphertext: "malformed",
	})
	select {
	case <-request.PrivateV2SettledCh:
	default:
		t.Fatal("invalid committed chunk did not release settlement waiter")
	}
}

func TestPrivateV2DisconnectAfterContentAlwaysResolvesSettlement(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	server := &Server{registry: reg, settlements: newSettlementHolder(), logger: logger}
	reg.SetPendingDisconnectedHook(server.handlePrivateV2PendingDisconnect)
	provider := reg.Register("disconnect-after-content", nil, &protocol.RegisterMessage{})
	request := &registry.PendingRequest{
		RequestID: "disconnect-after-content", Model: "model", ProviderID: provider.ID,
		PrivateV2ChunkCh:   make(chan protocol.PrivateChunkV2Message, 1),
		PrivateV2SettledCh: make(chan struct{}), PrivateV2DeliveryCh: make(chan struct{}),
	}
	request.MarkContentCommitted()
	provider.AddPending(request)
	reg.Disconnect(provider.ID)
	select {
	case <-request.PrivateV2SettledCh:
	case <-time.After(time.Second):
		t.Fatal("provider disconnect left committed private-v2 settlement waiting")
	}
	if !request.IsReservationFinalized() {
		t.Fatal("provider disconnect did not finalize the no-terminal refund")
	}
}

func TestLegacyPrivacyTierHeader(t *testing.T) {
	handler := privacyTierHandler(legacyPrivacyTier, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	response := httptest.NewRecorder()
	handler(response, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))
	if got := response.Header().Get("X-Darkbloom-Privacy-Tier"); got != legacyPrivacyTier {
		t.Fatalf("privacy tier = %q", got)
	}
}

func derivePrivateV2GoldenKey(t *testing.T, shared, salt, digest []byte, direction string) []byte {
	t.Helper()
	reader := hkdf.New(sha256.New, shared, salt, append([]byte("darkbloom/private-v2/"+direction+"\x00"), digest...))
	key := make([]byte, 32)
	if _, err := io.ReadFull(reader, key); err != nil {
		t.Fatal(err)
	}
	return key
}

func sealPrivateV2Golden(t *testing.T, key, nonce, plaintext, aad []byte) []byte {
	t.Helper()
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	var gcm cipher.AEAD
	gcm, err = cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return gcm.Seal(nil, nonce, plaintext, aad)
}

// TestPrivateV2GoldenVector is shared verbatim with the Swift and TypeScript
// implementations. Changing any byte is a protocol change, not a test update.
func TestPrivateV2GoldenVector(t *testing.T) {
	type goldenVector struct {
		ProviderPrivateKey string                               `json:"provider_private_key"`
		ProviderPublicKey  string                               `json:"provider_public_key"`
		ClientPrivateKey   string                               `json:"client_private_key"`
		ClientPublicKey    string                               `json:"client_public_key"`
		KDFSalt            string                               `json:"kdf_salt"`
		ProcessCertificate registry.PrivateV2ProcessCertificate `json:"process_certificate"`
		CertificateDigest  string                               `json:"certificate_digest"`
		TranscriptJSON     string                               `json:"transcript_json"`
		TranscriptDigest   string                               `json:"transcript_digest"`
		RequestNonce       string                               `json:"request_nonce"`
		RequestPlaintext   string                               `json:"request_plaintext"`
		RequestCiphertext  string                               `json:"request_ciphertext"`
		ResponseNonce      string                               `json:"response_nonce"`
		ResponsePlaintext  string                               `json:"response_plaintext"`
		ResponseCiphertext string                               `json:"response_ciphertext"`
	}
	fixturePath := filepath.Join("..", "..", "console-ui", "__tests__", "fixtures", "private-v2-golden.json")
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var vector goldenVector
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	decode := func(value string) []byte {
		decoded, err := base64.RawURLEncoding.DecodeString(value)
		if err != nil {
			t.Fatal(err)
		}
		return decoded
	}
	providerPrivate := decode(vector.ProviderPrivateKey)
	clientPrivate := decode(vector.ClientPrivateKey)
	providerPublic, err := curve25519.X25519(providerPrivate, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	clientPublic, err := curve25519.X25519(clientPrivate, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	if got := base64.StdEncoding.EncodeToString(providerPublic); got != vector.ProviderPublicKey {
		t.Fatalf("provider public key = %s", got)
	}
	if got := base64.RawURLEncoding.EncodeToString(clientPublic); got != vector.ClientPublicKey {
		t.Fatalf("client public key = %s", got)
	}
	certificateBytes, err := canonicalPrivateV2ProcessCertificate(vector.ProcessCertificate)
	if err != nil {
		t.Fatal(err)
	}
	certificateHash := sha256.Sum256(certificateBytes)
	if got := base64.RawURLEncoding.EncodeToString(certificateHash[:]); got != vector.CertificateDigest {
		t.Fatalf("certificate digest = %s; canonical=%s", got, certificateBytes)
	}
	var transcript privateV2Transcript
	if err := json.Unmarshal([]byte(vector.TranscriptJSON), &transcript); err != nil {
		t.Fatal(err)
	}
	transcriptBytes, err := canonicalPrivateV2Transcript(transcript)
	if err != nil {
		t.Fatal(err)
	}
	if string(transcriptBytes) != vector.TranscriptJSON {
		t.Fatalf("transcript canonical bytes = %s", transcriptBytes)
	}
	digest := sha256.Sum256(transcriptBytes)
	if got := base64.RawURLEncoding.EncodeToString(digest[:]); got != vector.TranscriptDigest {
		t.Fatalf("transcript digest = %s", got)
	}
	shared, err := curve25519.X25519(clientPrivate, providerPublic)
	if err != nil {
		t.Fatal(err)
	}
	salt := decode(vector.KDFSalt)
	requestKey := derivePrivateV2GoldenKey(t, shared, salt, digest[:], "request")
	responseKey := derivePrivateV2GoldenKey(t, shared, salt, digest[:], "response")
	requestCiphertext := sealPrivateV2Golden(t, requestKey, decode(vector.RequestNonce),
		[]byte(vector.RequestPlaintext), digest[:])
	if got := base64.RawURLEncoding.EncodeToString(requestCiphertext); got != vector.RequestCiphertext {
		t.Fatalf("request ciphertext = %s", got)
	}
	responseAAD := append(append([]byte(nil), digest[:]...), make([]byte, 8)...)
	responseCiphertext := sealPrivateV2Golden(t, responseKey, decode(vector.ResponseNonce),
		[]byte(vector.ResponsePlaintext), responseAAD)
	if got := base64.RawURLEncoding.EncodeToString(responseCiphertext); got != vector.ResponseCiphertext {
		t.Fatalf("response ciphertext = %s", got)
	}
}
