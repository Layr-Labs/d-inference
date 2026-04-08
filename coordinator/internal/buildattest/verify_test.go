package buildattest

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

// makeTestCert creates a self-signed X.509 certificate with Fulcio OID extensions.
func makeTestCert(t *testing.T, claims CertClaims) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber:    big.NewInt(1),
		Subject:         pkix.Name{CommonName: "test"},
		NotBefore:       time.Now().Add(-time.Hour),
		NotAfter:        time.Now().Add(time.Hour),
		ExtraExtensions: []pkix.Extension{},
	}

	// Add OID extensions as DER-encoded UTF8Strings (V2 format).
	addExt := func(oid asn1.ObjectIdentifier, val string) {
		derVal, _ := asn1.Marshal(val)
		template.ExtraExtensions = append(template.ExtraExtensions, pkix.Extension{
			Id:    oid,
			Value: derVal,
		})
	}

	if claims.Issuer != "" {
		addExt(OIDIssuerV2, claims.Issuer)
	}
	if claims.SourceRepoURI != "" {
		addExt(OIDSourceRepositoryURI, claims.SourceRepoURI)
	}
	if claims.SourceRepoRef != "" {
		addExt(OIDSourceRepositoryRef, claims.SourceRepoRef)
	}
	if claims.BuildConfigURI != "" {
		addExt(OIDBuildConfigURI, claims.BuildConfigURI)
	}
	if claims.BuildSignerURI != "" {
		addExt(OIDBuildSignerURI, claims.BuildSignerURI)
	}
	if claims.BuildTrigger != "" {
		addExt(OIDBuildTrigger, claims.BuildTrigger)
	}
	if claims.RunnerEnvironment != "" {
		addExt(OIDRunnerEnvironment, claims.RunnerEnvironment)
	}
	if claims.RunInvocationURI != "" {
		addExt(OIDRunInvocationURI, claims.RunInvocationURI)
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	return der
}

// makeTestBundle creates a Sigstore bundle JSON with a certificate and optional actor.
func makeTestBundle(t *testing.T, certDER []byte, actor string) json.RawMessage {
	t.Helper()
	certB64 := base64.StdEncoding.EncodeToString(certDER)

	// Build SLSA predicate with actor.
	predicate := map[string]interface{}{
		"buildDefinition": map[string]interface{}{
			"internalParameters": map[string]interface{}{
				"github": map[string]interface{}{
					"actor":    actor,
					"actor_id": "12345",
				},
			},
		},
	}
	predicateJSON, _ := json.Marshal(predicate)

	statement := map[string]interface{}{
		"_type":         "https://in-toto.io/Statement/v1",
		"subject":       []map[string]interface{}{{"name": "test", "digest": map[string]string{"sha256": "abc123"}}},
		"predicateType": "https://slsa.dev/provenance/v1",
		"predicate":     json.RawMessage(predicateJSON),
	}
	stmtJSON, _ := json.Marshal(statement)
	payloadB64 := base64.StdEncoding.EncodeToString(stmtJSON)

	bundle := map[string]interface{}{
		"mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.3",
		"verificationMaterial": map[string]interface{}{
			"certificate": map[string]interface{}{
				"rawBytes": certB64,
			},
		},
		"dsseEnvelope": map[string]interface{}{
			"payload":     payloadB64,
			"payloadType": "application/vnd.in-toto+json",
			"signatures":  []map[string]interface{}{{"sig": "dGVzdA==", "keyid": ""}},
		},
	}

	data, _ := json.Marshal(bundle)
	return data
}

// validClaims returns a CertClaims that passes the default policy.
func validClaims() CertClaims {
	return CertClaims{
		Issuer:            "https://token.actions.githubusercontent.com",
		SourceRepoURI:     "https://github.com/Layr-Labs/d-inference",
		SourceRepoRef:     "refs/tags/v0.2.35",
		BuildConfigURI:    "https://github.com/Layr-Labs/d-inference/.github/workflows/release.yml@refs/tags/v0.2.35",
		BuildSignerURI:    "https://github.com/Layr-Labs/d-inference/.github/workflows/release.yml@refs/tags/v0.2.35",
		BuildTrigger:      "push",
		RunnerEnvironment: "github-hosted",
		RunInvocationURI:  "https://github.com/Layr-Labs/d-inference/actions/runs/12345",
	}
}

// defaultPolicy returns a policy matching the default configuration.
func defaultPolicy() Policy {
	return Policy{
		Required:            true,
		TrustedRepo:         "Layr-Labs/d-inference",
		TrustedWorkflow:     ".github/workflows/release.yml",
		TrustedTriggers:     []string{"push"},
		RequireGitHubHosted: true,
		GitHubToken:         "test-token",
	}
}

// --- Test 1: Valid attestation ---

func TestVerifyBundle_ValidAttestation(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "Gajesh2007")
	policy := defaultPolicy()

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Verified {
		t.Fatalf("expected verified, got errors: %v", result.Errors)
	}
	if result.Claims.SourceRepoURI != claims.SourceRepoURI {
		t.Errorf("repo URI mismatch: got %q, want %q", result.Claims.SourceRepoURI, claims.SourceRepoURI)
	}
	if result.Actor != "Gajesh2007" {
		t.Errorf("actor mismatch: got %q, want %q", result.Actor, "Gajesh2007")
	}
}

// --- Test 2: Wrong repo ---

func TestVerifyBundle_WrongRepo(t *testing.T) {
	claims := validClaims()
	claims.SourceRepoURI = "https://github.com/evil-org/evil-repo"
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "attacker")
	policy := defaultPolicy()

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected verification to fail for wrong repo")
	}
	if len(result.Errors) == 0 {
		t.Fatal("expected errors for wrong repo")
	}
}

// --- Test 3: Wrong workflow ---

func TestVerifyBundle_WrongWorkflow(t *testing.T) {
	claims := validClaims()
	claims.BuildConfigURI = "https://github.com/Layr-Labs/d-inference/.github/workflows/ci.yml@refs/heads/main"
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "Gajesh2007")
	policy := defaultPolicy()

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected verification to fail for wrong workflow")
	}
}

// --- Test 4: Wrong trigger ---

func TestVerifyBundle_WrongTrigger(t *testing.T) {
	claims := validClaims()
	claims.BuildTrigger = "workflow_dispatch"
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "Gajesh2007")
	policy := defaultPolicy()

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected verification to fail for wrong trigger")
	}
}

// --- Test 5: Self-hosted runner ---

func TestVerifyBundle_SelfHostedRunner(t *testing.T) {
	claims := validClaims()
	claims.RunnerEnvironment = "self-hosted"
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "Gajesh2007")
	policy := defaultPolicy()

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected verification to fail for self-hosted runner")
	}
}

// --- Test 6: Untrusted actor ---

func TestVerifyBundle_UntrustedActor(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "malicious-user")
	policy := defaultPolicy()
	policy.TrustedActors = []string{"Gajesh2007", "trusted-bot"}

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected verification to fail for untrusted actor")
	}
}

// --- Test 7: Empty attestations ---

func TestVerifyBundle_EmptyAttestations(t *testing.T) {
	policy := defaultPolicy()

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(AttestationResponse{Attestations: []AttestationEntry{}})
	}))
	defer ts.Close()

	// Use the internal function with mock server
	resp, err := fetchAttestationsWithClient(context.Background(), ts.Client(), ts.URL, "Layr-Labs", "d-inference", "deadbeef", "test-token")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(resp.Attestations) != 0 {
		t.Fatal("expected empty attestations")
	}

	// Test VerifyRelease with empty attestations
	result, err := verifyReleaseWithClient(context.Background(), ts.Client(), ts.URL, policy, "deadbeef")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected not verified with empty attestations")
	}
	if len(result.Errors) == 0 {
		t.Fatal("expected errors when required and no attestations")
	}
}

// --- Test 8: Malformed bundle ---

func TestVerifyBundle_MalformedBundle(t *testing.T) {
	policy := defaultPolicy()

	_, err := VerifyBundle(json.RawMessage(`{invalid json`), policy)
	if err == nil {
		t.Fatal("expected error for malformed bundle")
	}
}

// --- Test 9: No certificate ---

func TestVerifyBundle_NoCertificate(t *testing.T) {
	policy := defaultPolicy()

	bundle := map[string]interface{}{
		"mediaType":            "application/vnd.dev.sigstore.bundle+json;version=0.3",
		"verificationMaterial": map[string]interface{}{},
	}
	data, _ := json.Marshal(bundle)

	_, err := VerifyBundle(data, policy)
	if err == nil {
		t.Fatal("expected error for bundle with no certificate")
	}
}

// --- Test 10: Multiple attestations, one valid ---

func TestVerifyBundle_MultipleAttestations_OneValid(t *testing.T) {
	policy := defaultPolicy()

	// First attestation: wrong repo
	badClaims := validClaims()
	badClaims.SourceRepoURI = "https://github.com/evil-org/evil-repo"
	badCertDER := makeTestCert(t, badClaims)
	badBundle := makeTestBundle(t, badCertDER, "evil")

	// Second attestation: valid
	goodClaims := validClaims()
	goodCertDER := makeTestCert(t, goodClaims)
	goodBundle := makeTestBundle(t, goodCertDER, "Gajesh2007")

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := AttestationResponse{
			Attestations: []AttestationEntry{
				{Bundle: badBundle},
				{Bundle: goodBundle},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	result, err := verifyReleaseWithClient(context.Background(), ts.Client(), ts.URL, policy, "deadbeef")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Verified {
		t.Fatalf("expected verified (second attestation is valid), got errors: %v", result.Errors)
	}
}

// --- Test 11: Policy not required, no attestation ---

func TestVerifyBundle_PolicyNotRequired_NoAttestation(t *testing.T) {
	policy := defaultPolicy()
	policy.Required = false

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(AttestationResponse{Attestations: []AttestationEntry{}})
	}))
	defer ts.Close()

	result, err := verifyReleaseWithClient(context.Background(), ts.Client(), ts.URL, policy, "deadbeef")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Verified {
		t.Fatal("expected not verified with no attestation")
	}
	if len(result.Warnings) == 0 {
		t.Fatal("expected warnings when not required and no attestation")
	}
	if len(result.Errors) != 0 {
		t.Fatalf("expected no errors when not required, got: %v", result.Errors)
	}
}

// --- Test 12: Policy required, no token ---

func TestVerifyBundle_PolicyRequired_NoToken(t *testing.T) {
	policy := Policy{
		Required:    true,
		TrustedRepo: "Layr-Labs/d-inference",
		GitHubToken: "", // no token
	}

	_, err := VerifyRelease(context.Background(), policy, "deadbeef")
	if err == nil {
		t.Fatal("expected error when required but no token")
	}
}

// --- Test 13: DER-encoded extensions ---

func TestExtractClaims_DEREncoded(t *testing.T) {
	claims := CertClaims{
		Issuer:            "https://token.actions.githubusercontent.com",
		SourceRepoURI:     "https://github.com/Layr-Labs/d-inference",
		BuildConfigURI:    "https://github.com/Layr-Labs/d-inference/.github/workflows/release.yml@refs/tags/v1.0.0",
		BuildTrigger:      "push",
		RunnerEnvironment: "github-hosted",
	}

	certDER := makeTestCert(t, claims)
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		t.Fatalf("parsing cert: %v", err)
	}

	extracted, err := ExtractClaims(cert)
	if err != nil {
		t.Fatalf("extracting claims: %v", err)
	}

	if extracted.Issuer != claims.Issuer {
		t.Errorf("issuer: got %q, want %q", extracted.Issuer, claims.Issuer)
	}
	if extracted.SourceRepoURI != claims.SourceRepoURI {
		t.Errorf("source repo URI: got %q, want %q", extracted.SourceRepoURI, claims.SourceRepoURI)
	}
	if extracted.BuildConfigURI != claims.BuildConfigURI {
		t.Errorf("build config URI: got %q, want %q", extracted.BuildConfigURI, claims.BuildConfigURI)
	}
	if extracted.BuildTrigger != claims.BuildTrigger {
		t.Errorf("build trigger: got %q, want %q", extracted.BuildTrigger, claims.BuildTrigger)
	}
	if extracted.RunnerEnvironment != claims.RunnerEnvironment {
		t.Errorf("runner env: got %q, want %q", extracted.RunnerEnvironment, claims.RunnerEnvironment)
	}
}

// --- Test 14: Legacy raw byte extensions ---

func TestExtractClaims_LegacyRawBytes(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test-legacy"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		ExtraExtensions: []pkix.Extension{
			{Id: OIDIssuerLegacy, Value: []byte("https://token.actions.githubusercontent.com")},
			{Id: OIDWorkflowTrigger, Value: []byte("push")},
			{Id: OIDWorkflowRepo, Value: []byte("https://github.com/Layr-Labs/d-inference")},
			{Id: OIDWorkflowRef, Value: []byte("refs/tags/v1.0.0")},
			{Id: OIDWorkflowName, Value: []byte("release.yml")},
		},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("creating cert: %v", err)
	}

	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		t.Fatalf("parsing cert: %v", err)
	}

	extracted, err := ExtractClaims(cert)
	if err != nil {
		t.Fatalf("extracting claims: %v", err)
	}

	if extracted.Issuer != "https://token.actions.githubusercontent.com" {
		t.Errorf("legacy issuer: got %q", extracted.Issuer)
	}
	if extracted.BuildTrigger != "push" {
		t.Errorf("legacy trigger: got %q", extracted.BuildTrigger)
	}
	if extracted.SourceRepoURI != "https://github.com/Layr-Labs/d-inference" {
		t.Errorf("legacy repo: got %q", extracted.SourceRepoURI)
	}
	if extracted.SourceRepoRef != "refs/tags/v1.0.0" {
		t.Errorf("legacy ref: got %q", extracted.SourceRepoRef)
	}
	if extracted.BuildConfigURI != "release.yml" {
		t.Errorf("legacy workflow name: got %q", extracted.BuildConfigURI)
	}
}

// --- Test 15: Actor extraction from SLSA predicate ---

func TestExtractActorFromPredicate(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "test-actor-123")

	var bundle SigstoreBundle
	if err := json.Unmarshal(bundleJSON, &bundle); err != nil {
		t.Fatalf("parsing bundle: %v", err)
	}

	actor := ExtractActorFromPredicate(&bundle)
	if actor != "test-actor-123" {
		t.Errorf("actor: got %q, want %q", actor, "test-actor-123")
	}
}

func TestExtractActorFromPredicate_NoDSSEEnvelope(t *testing.T) {
	bundle := &SigstoreBundle{}
	actor := ExtractActorFromPredicate(bundle)
	if actor != "" {
		t.Errorf("expected empty actor, got %q", actor)
	}
}

func TestExtractActorFromPredicate_EmptyPayload(t *testing.T) {
	bundle := &SigstoreBundle{
		DSSEEnvelope: &dsseEnvelope{Payload: ""},
	}
	actor := ExtractActorFromPredicate(bundle)
	if actor != "" {
		t.Errorf("expected empty actor, got %q", actor)
	}
}

// --- Test 16: GitHub API mock ---

func TestFetchAttestations_MockAPI(t *testing.T) {
	expectedDigest := "abcdef1234567890"

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify request format
		expectedPath := fmt.Sprintf("/repos/Layr-Labs/d-inference/attestations/sha256:%s", expectedDigest)
		if r.URL.Path != expectedPath {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("unexpected auth header: %s", r.Header.Get("Authorization"))
		}
		if r.Header.Get("Accept") != "application/vnd.github+json" {
			t.Errorf("unexpected accept header: %s", r.Header.Get("Accept"))
		}

		resp := AttestationResponse{
			Attestations: []AttestationEntry{
				{Bundle: json.RawMessage(`{"test": true}`)},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer ts.Close()

	resp, err := fetchAttestationsWithClient(context.Background(), ts.Client(), ts.URL, "Layr-Labs", "d-inference", expectedDigest, "test-token")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(resp.Attestations) != 1 {
		t.Fatalf("expected 1 attestation, got %d", len(resp.Attestations))
	}
}

// --- Test 17: 404 returns empty ---

func TestFetchAttestations_NotFound(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer ts.Close()

	resp, err := fetchAttestationsWithClient(context.Background(), ts.Client(), ts.URL, "Layr-Labs", "d-inference", "nonexistent", "test-token")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(resp.Attestations) != 0 {
		t.Fatalf("expected 0 attestations on 404, got %d", len(resp.Attestations))
	}
}

// --- Test 18: 429 returns error ---

func TestFetchAttestations_RateLimit(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer ts.Close()

	_, err := fetchAttestationsWithClient(context.Background(), ts.Client(), ts.URL, "Layr-Labs", "d-inference", "digest", "test-token")
	if err == nil {
		t.Fatal("expected error on rate limit")
	}
}

// --- Test 19: 500 returns error ---

func TestFetchAttestations_ServerError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("internal server error"))
	}))
	defer ts.Close()

	_, err := fetchAttestationsWithClient(context.Background(), ts.Client(), ts.URL, "Layr-Labs", "d-inference", "digest", "test-token")
	if err == nil {
		t.Fatal("expected error on server error")
	}
}

// --- Test 20: PolicyFromEnv ---

func TestPolicyFromEnv(t *testing.T) {
	// Save and restore env vars
	envVars := []string{
		"ATTESTATION_REQUIRED",
		"TRUSTED_REPO",
		"TRUSTED_WORKFLOW",
		"TRUSTED_ACTORS",
		"TRUSTED_TRIGGERS",
		"GITHUB_ATTESTATION_TOKEN",
	}
	saved := make(map[string]string)
	for _, k := range envVars {
		saved[k] = os.Getenv(k)
	}
	defer func() {
		for k, v := range saved {
			if v == "" {
				os.Unsetenv(k)
			} else {
				os.Setenv(k, v)
			}
		}
	}()

	// Set test values
	os.Setenv("ATTESTATION_REQUIRED", "true")
	os.Setenv("TRUSTED_REPO", "test-org/test-repo")
	os.Setenv("TRUSTED_WORKFLOW", ".github/workflows/test.yml")
	os.Setenv("TRUSTED_ACTORS", "user1, user2, user3")
	os.Setenv("TRUSTED_TRIGGERS", "push, workflow_dispatch")
	os.Setenv("GITHUB_ATTESTATION_TOKEN", "ghp_test123")

	p := PolicyFromEnv()

	if !p.Required {
		t.Error("expected Required=true")
	}
	if p.TrustedRepo != "test-org/test-repo" {
		t.Errorf("TrustedRepo: got %q", p.TrustedRepo)
	}
	if p.TrustedWorkflow != ".github/workflows/test.yml" {
		t.Errorf("TrustedWorkflow: got %q", p.TrustedWorkflow)
	}
	if len(p.TrustedActors) != 3 || p.TrustedActors[0] != "user1" || p.TrustedActors[1] != "user2" || p.TrustedActors[2] != "user3" {
		t.Errorf("TrustedActors: got %v", p.TrustedActors)
	}
	if len(p.TrustedTriggers) != 2 || p.TrustedTriggers[0] != "push" || p.TrustedTriggers[1] != "workflow_dispatch" {
		t.Errorf("TrustedTriggers: got %v", p.TrustedTriggers)
	}
	if p.GitHubToken != "ghp_test123" {
		t.Errorf("GitHubToken: got %q", p.GitHubToken)
	}
	if !p.Enabled() {
		t.Error("expected Enabled()=true with token set")
	}
}

func TestPolicyFromEnv_Defaults(t *testing.T) {
	// Save and restore env vars
	envVars := []string{
		"ATTESTATION_REQUIRED",
		"TRUSTED_REPO",
		"TRUSTED_WORKFLOW",
		"TRUSTED_ACTORS",
		"TRUSTED_TRIGGERS",
		"GITHUB_ATTESTATION_TOKEN",
	}
	saved := make(map[string]string)
	for _, k := range envVars {
		saved[k] = os.Getenv(k)
	}
	defer func() {
		for k, v := range saved {
			if v == "" {
				os.Unsetenv(k)
			} else {
				os.Setenv(k, v)
			}
		}
	}()

	// Clear all env vars
	for _, k := range envVars {
		os.Unsetenv(k)
	}

	p := PolicyFromEnv()

	if p.Required {
		t.Error("expected Required=false by default")
	}
	if p.TrustedRepo != "Layr-Labs/d-inference" {
		t.Errorf("default TrustedRepo: got %q", p.TrustedRepo)
	}
	if p.TrustedWorkflow != ".github/workflows/release.yml" {
		t.Errorf("default TrustedWorkflow: got %q", p.TrustedWorkflow)
	}
	if len(p.TrustedTriggers) != 1 || p.TrustedTriggers[0] != "push" {
		t.Errorf("default TrustedTriggers: got %v", p.TrustedTriggers)
	}
	if p.RequireGitHubHosted != true {
		t.Error("expected RequireGitHubHosted=true by default")
	}
	if p.Enabled() {
		t.Error("expected Enabled()=false without token")
	}
}

// --- Additional edge case tests ---

func TestVerifyBundle_TrustedActorMatch(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "Gajesh2007")
	policy := defaultPolicy()
	policy.TrustedActors = []string{"Gajesh2007", "trusted-bot"}

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Verified {
		t.Fatalf("expected verified for trusted actor, got errors: %v", result.Errors)
	}
}

func TestVerifyBundle_NoActorCheck_WhenNoTrustedActors(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	bundleJSON := makeTestBundle(t, certDER, "anyone")
	policy := defaultPolicy()
	policy.TrustedActors = nil // no actor restriction

	result, err := VerifyBundle(bundleJSON, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Verified {
		t.Fatalf("expected verified when no actor restriction, got errors: %v", result.Errors)
	}
}

func TestVerifyBundle_CertChainFormat(t *testing.T) {
	claims := validClaims()
	certDER := makeTestCert(t, claims)
	certB64 := base64.StdEncoding.EncodeToString(certDER)

	// Build bundle with certificate chain format (v0.1/v0.2)
	bundle := map[string]interface{}{
		"mediaType": "application/vnd.dev.sigstore.bundle+json;version=0.1",
		"verificationMaterial": map[string]interface{}{
			"x509CertificateChain": map[string]interface{}{
				"certificates": []map[string]interface{}{
					{"rawBytes": certB64},
				},
			},
		},
	}
	data, _ := json.Marshal(bundle)

	policy := defaultPolicy()
	result, err := VerifyBundle(data, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Verified {
		t.Fatalf("expected verified with cert chain format, got errors: %v", result.Errors)
	}
}

func TestExtractLeafCert_EmptyCertChain(t *testing.T) {
	bundle := &SigstoreBundle{
		VerificationMaterial: verificationMaterial{
			X509CertificateChain: &certificateChain{
				Certificates: []certEntry{},
			},
		},
	}
	_, err := ExtractLeafCert(bundle)
	if err == nil {
		t.Fatal("expected error for empty cert chain")
	}
}

// --- Helper for testing VerifyRelease with a mock server ---

func verifyReleaseWithClient(ctx context.Context, client *http.Client, baseURL string, policy Policy, bundleHash string) (*VerificationResult, error) {
	// Temporarily override the default client and API base for testing.
	origClient := defaultClient
	defaultClient = client
	defer func() { defaultClient = origClient }()

	parts := fmt.Sprintf("%s/%s", policy.TrustedRepo, "unused")
	_ = parts

	owner := "Layr-Labs"
	repo := "d-inference"

	resp, err := fetchAttestationsWithClient(ctx, client, baseURL, owner, repo, bundleHash, policy.GitHubToken)
	if err != nil {
		if policy.Required {
			return nil, fmt.Errorf("fetching attestations: %w", err)
		}
		return &VerificationResult{
			Verified: false,
			Warnings: []string{fmt.Sprintf("attestation fetch failed: %v", err)},
		}, nil
	}

	if len(resp.Attestations) == 0 {
		msg := fmt.Sprintf("no attestations found for sha256:%s", bundleHash)
		if policy.Required {
			return &VerificationResult{Verified: false, Errors: []string{msg}}, nil
		}
		return &VerificationResult{Verified: false, Warnings: []string{msg}}, nil
	}

	var allErrors []string
	for i, entry := range resp.Attestations {
		result, err := VerifyBundle(entry.Bundle, policy)
		if err != nil {
			allErrors = append(allErrors, fmt.Sprintf("attestation[%d]: %v", i, err))
			continue
		}
		if result.Verified {
			return result, nil
		}
		for _, e := range result.Errors {
			allErrors = append(allErrors, fmt.Sprintf("attestation[%d]: %s", i, e))
		}
	}

	msg := fmt.Sprintf("no attestation matched policy: %s", joinErrors(allErrors))
	if policy.Required {
		return &VerificationResult{Verified: false, Errors: []string{msg}}, nil
	}
	return &VerificationResult{Verified: false, Warnings: []string{msg}}, nil
}

func joinErrors(errs []string) string {
	result := ""
	for i, e := range errs {
		if i > 0 {
			result += "; "
		}
		result += e
	}
	return result
}
