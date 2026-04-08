package buildattest

import (
	"context"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log"
	"strings"
)

// Fulcio OID extensions for GitHub Actions OIDC claims.
// See: https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md
var (
	OIDIssuerV2            = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 8}
	OIDBuildSignerURI      = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 9}
	OIDRunnerEnvironment   = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 11}
	OIDSourceRepositoryURI = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 12}
	OIDSourceRepositoryRef = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 14}
	OIDBuildConfigURI      = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 18}
	OIDBuildTrigger        = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 20}
	OIDRunInvocationURI    = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 21}

	// Legacy extensions (raw string values, not DER-encoded).
	OIDIssuerLegacy    = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 1}
	OIDWorkflowTrigger = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 2}
	OIDWorkflowName    = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 4}
	OIDWorkflowRepo    = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 5}
	OIDWorkflowRef     = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 57264, 1, 6}
)

// CertClaims holds the extracted OIDC claims from a Fulcio certificate.
type CertClaims struct {
	Issuer            string
	SourceRepoURI     string
	SourceRepoRef     string
	BuildConfigURI    string
	BuildSignerURI    string
	BuildTrigger      string
	RunnerEnvironment string
	RunInvocationURI  string
}

// SigstoreBundle represents the relevant parts of a Sigstore bundle.
type SigstoreBundle struct {
	MediaType            string               `json:"mediaType"`
	VerificationMaterial verificationMaterial `json:"verificationMaterial"`
	DSSEEnvelope         *dsseEnvelope        `json:"dsseEnvelope"`
}

type verificationMaterial struct {
	X509CertificateChain *certificateChain `json:"x509CertificateChain"`
	Certificate          *singleCert       `json:"certificate"`
}

type certificateChain struct {
	Certificates []certEntry `json:"certificates"`
}

type singleCert struct {
	RawBytes string `json:"rawBytes"`
}

type certEntry struct {
	RawBytes string `json:"rawBytes"`
}

type dsseEnvelope struct {
	Payload     string          `json:"payload"`
	PayloadType string          `json:"payloadType"`
	Signatures  []dsseSignature `json:"signatures"`
}

type dsseSignature struct {
	Sig   string `json:"sig"`
	KeyID string `json:"keyid"`
}

// InTotoStatement represents an in-toto statement (for extracting actor from SLSA predicate).
type InTotoStatement struct {
	Type          string          `json:"_type"`
	Subject       []Subject       `json:"subject"`
	PredicateType string          `json:"predicateType"`
	Predicate     json.RawMessage `json:"predicate"`
}

// Subject is a subject in an in-toto statement.
type Subject struct {
	Name   string            `json:"name"`
	Digest map[string]string `json:"digest"`
}

// SLSAPredicate is a partial representation for extracting the actor.
type SLSAPredicate struct {
	BuildDefinition *BuildDefinition `json:"buildDefinition"`
}

// BuildDefinition is the build definition in a SLSA predicate.
type BuildDefinition struct {
	InternalParameters json.RawMessage `json:"internalParameters"`
}

// GitHubInternalParams contains the GitHub context from the SLSA predicate.
type GitHubInternalParams struct {
	GitHub *GitHubContext `json:"github"`
}

// GitHubContext holds the actor information from the GitHub Actions context.
type GitHubContext struct {
	Actor   string `json:"actor"`
	ActorID string `json:"actor_id"`
}

// VerificationResult contains the outcome of attestation verification.
type VerificationResult struct {
	Verified bool
	Claims   *CertClaims
	Actor    string // from SLSA predicate
	Errors   []string
	Warnings []string
}

// VerifyRelease is the main entry point: fetches attestations from GitHub and verifies
// at least one matches the policy.
func VerifyRelease(ctx context.Context, policy Policy, bundleHash string) (*VerificationResult, error) {
	if !policy.Enabled() {
		if policy.Required {
			return nil, fmt.Errorf("attestation required but GITHUB_ATTESTATION_TOKEN not configured")
		}
		return &VerificationResult{
			Verified: false,
			Warnings: []string{"attestation verification skipped: no GitHub token configured"},
		}, nil
	}

	parts := strings.SplitN(policy.TrustedRepo, "/", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid TrustedRepo format: %q (expected owner/repo)", policy.TrustedRepo)
	}
	owner, repo := parts[0], parts[1]

	resp, err := FetchAttestations(ctx, owner, repo, bundleHash, policy.GitHubToken)
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

	// Check if any attestation matches the policy.
	var allErrors []string
	for i, entry := range resp.Attestations {
		result, err := VerifyBundle(entry.Bundle, policy)
		if err != nil {
			allErrors = append(allErrors, fmt.Sprintf("attestation[%d]: %v", i, err))
			continue
		}
		if result.Verified {
			log.Printf("[attestation] verified release sha256:%s (repo=%s, workflow=%s, trigger=%s, runner=%s, actor=%s)",
				bundleHash, result.Claims.SourceRepoURI, result.Claims.BuildConfigURI,
				result.Claims.BuildTrigger, result.Claims.RunnerEnvironment, result.Actor)
			return result, nil
		}
		for _, e := range result.Errors {
			allErrors = append(allErrors, fmt.Sprintf("attestation[%d]: %s", i, e))
		}
	}

	msg := fmt.Sprintf("no attestation matched policy: %s", strings.Join(allErrors, "; "))
	if policy.Required {
		return &VerificationResult{Verified: false, Errors: []string{msg}}, nil
	}
	return &VerificationResult{Verified: false, Warnings: []string{msg}}, nil
}

// VerifyBundle parses a single attestation bundle and checks it against the policy.
func VerifyBundle(bundleJSON json.RawMessage, policy Policy) (*VerificationResult, error) {
	var bundle SigstoreBundle
	if err := json.Unmarshal(bundleJSON, &bundle); err != nil {
		return nil, fmt.Errorf("parsing bundle: %w", err)
	}

	cert, err := ExtractLeafCert(&bundle)
	if err != nil {
		return nil, fmt.Errorf("extracting certificate: %w", err)
	}

	claims, err := ExtractClaims(cert)
	if err != nil {
		return nil, fmt.Errorf("extracting claims: %w", err)
	}

	// Extract actor from SLSA predicate if available.
	actor := ExtractActorFromPredicate(&bundle)

	result := &VerificationResult{
		Claims: claims,
		Actor:  actor,
	}

	// Check each policy constraint.
	if policy.TrustedRepo != "" {
		expectedURI := "https://github.com/" + policy.TrustedRepo
		if !strings.HasPrefix(claims.SourceRepoURI, expectedURI) {
			result.Errors = append(result.Errors, fmt.Sprintf("repo mismatch: got %q, want prefix %q", claims.SourceRepoURI, expectedURI))
		}
	}

	if policy.TrustedWorkflow != "" {
		if !strings.Contains(claims.BuildConfigURI, policy.TrustedWorkflow) {
			result.Errors = append(result.Errors, fmt.Sprintf("workflow mismatch: got %q, want contains %q", claims.BuildConfigURI, policy.TrustedWorkflow))
		}
	}

	if len(policy.TrustedTriggers) > 0 {
		matched := false
		for _, t := range policy.TrustedTriggers {
			if claims.BuildTrigger == t {
				matched = true
				break
			}
		}
		if !matched {
			result.Errors = append(result.Errors, fmt.Sprintf("trigger mismatch: got %q, want one of %v", claims.BuildTrigger, policy.TrustedTriggers))
		}
	}

	if policy.RequireGitHubHosted {
		if claims.RunnerEnvironment == "" {
			result.Errors = append(result.Errors, "runner environment not specified in certificate (required: \"github-hosted\")")
		} else if claims.RunnerEnvironment != "github-hosted" {
			result.Errors = append(result.Errors, fmt.Sprintf("runner mismatch: got %q, want \"github-hosted\"", claims.RunnerEnvironment))
		}
	}

	if len(policy.TrustedActors) > 0 && actor != "" {
		matched := false
		for _, a := range policy.TrustedActors {
			if actor == a {
				matched = true
				break
			}
		}
		if !matched {
			result.Errors = append(result.Errors, fmt.Sprintf("actor mismatch: got %q, want one of %v", actor, policy.TrustedActors))
		}
	}

	result.Verified = len(result.Errors) == 0
	return result, nil
}

// ExtractLeafCert extracts the leaf X.509 certificate from a Sigstore bundle.
func ExtractLeafCert(bundle *SigstoreBundle) (*x509.Certificate, error) {
	var rawB64 string

	// Try v0.3+ format (single certificate).
	if bundle.VerificationMaterial.Certificate != nil && bundle.VerificationMaterial.Certificate.RawBytes != "" {
		rawB64 = bundle.VerificationMaterial.Certificate.RawBytes
	}

	// Try v0.1/v0.2 format (certificate chain).
	if rawB64 == "" && bundle.VerificationMaterial.X509CertificateChain != nil {
		certs := bundle.VerificationMaterial.X509CertificateChain.Certificates
		if len(certs) == 0 {
			return nil, fmt.Errorf("empty certificate chain")
		}
		rawB64 = certs[0].RawBytes // leaf cert is first
	}

	if rawB64 == "" {
		return nil, fmt.Errorf("no certificate found in bundle")
	}

	derBytes, err := base64.StdEncoding.DecodeString(rawB64)
	if err != nil {
		// Try PEM decoding as fallback.
		block, _ := pem.Decode([]byte(rawB64))
		if block == nil {
			return nil, fmt.Errorf("decoding certificate: not base64 or PEM")
		}
		derBytes = block.Bytes
	}

	cert, err := x509.ParseCertificate(derBytes)
	if err != nil {
		return nil, fmt.Errorf("parsing X.509 certificate: %w", err)
	}

	return cert, nil
}

// ExtractClaims reads Fulcio OID extensions from the certificate.
func ExtractClaims(cert *x509.Certificate) (*CertClaims, error) {
	claims := &CertClaims{}

	for _, ext := range cert.Extensions {
		val := parseExtensionValue(ext.Value)

		switch {
		// Current V2 extensions (DER-encoded UTF8String).
		case ext.Id.Equal(OIDIssuerV2):
			claims.Issuer = val
		case ext.Id.Equal(OIDSourceRepositoryURI):
			claims.SourceRepoURI = val
		case ext.Id.Equal(OIDSourceRepositoryRef):
			claims.SourceRepoRef = val
		case ext.Id.Equal(OIDBuildConfigURI):
			claims.BuildConfigURI = val
		case ext.Id.Equal(OIDBuildSignerURI):
			claims.BuildSignerURI = val
		case ext.Id.Equal(OIDBuildTrigger):
			claims.BuildTrigger = val
		case ext.Id.Equal(OIDRunnerEnvironment):
			claims.RunnerEnvironment = val
		case ext.Id.Equal(OIDRunInvocationURI):
			claims.RunInvocationURI = val

		// Legacy extensions (raw string values) -- fallback if V2 not present.
		case ext.Id.Equal(OIDIssuerLegacy) && claims.Issuer == "":
			claims.Issuer = string(ext.Value)
		case ext.Id.Equal(OIDWorkflowTrigger) && claims.BuildTrigger == "":
			claims.BuildTrigger = string(ext.Value)
		case ext.Id.Equal(OIDWorkflowRepo) && claims.SourceRepoURI == "":
			claims.SourceRepoURI = string(ext.Value)
		case ext.Id.Equal(OIDWorkflowRef) && claims.SourceRepoRef == "":
			claims.SourceRepoRef = string(ext.Value)
		case ext.Id.Equal(OIDWorkflowName) && claims.BuildConfigURI == "":
			claims.BuildConfigURI = string(ext.Value)
		}
	}

	return claims, nil
}

// parseExtensionValue tries DER UTF8String decoding, falling back to raw bytes.
func parseExtensionValue(raw []byte) string {
	// Try DER-encoded UTF8String first (used by newer Fulcio extensions).
	var s string
	if _, err := asn1.Unmarshal(raw, &s); err == nil {
		return s
	}
	// Fallback: raw bytes as string (legacy extensions).
	return string(raw)
}

// ExtractActorFromPredicate extracts the GitHub actor from the SLSA predicate
// inside the DSSE envelope.
func ExtractActorFromPredicate(bundle *SigstoreBundle) string {
	if bundle.DSSEEnvelope == nil || bundle.DSSEEnvelope.Payload == "" {
		return ""
	}

	payload, err := base64.StdEncoding.DecodeString(bundle.DSSEEnvelope.Payload)
	if err != nil {
		// Try URL-safe base64.
		payload, err = base64.URLEncoding.DecodeString(bundle.DSSEEnvelope.Payload)
		if err != nil {
			return ""
		}
	}

	var stmt InTotoStatement
	if err := json.Unmarshal(payload, &stmt); err != nil {
		return ""
	}

	var pred SLSAPredicate
	if err := json.Unmarshal(stmt.Predicate, &pred); err != nil {
		return ""
	}

	if pred.BuildDefinition == nil {
		return ""
	}

	var params GitHubInternalParams
	if err := json.Unmarshal(pred.BuildDefinition.InternalParameters, &params); err != nil {
		return ""
	}

	if params.GitHub != nil {
		return params.GitHub.Actor
	}
	return ""
}
