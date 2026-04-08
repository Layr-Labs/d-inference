package buildattest

import (
	"os"
	"strings"
)

// Policy defines the attestation verification policy.
type Policy struct {
	// Required controls whether attestation verification is mandatory.
	// When false, verification failures are logged as warnings but releases are accepted.
	Required bool

	// TrustedRepo is the expected source repository (e.g. "Layr-Labs/d-inference").
	TrustedRepo string

	// TrustedWorkflow is the expected workflow file path (e.g. ".github/workflows/release.yml").
	TrustedWorkflow string

	// TrustedActors is the list of GitHub usernames allowed to trigger releases.
	TrustedActors []string

	// TrustedTriggers is the list of allowed event triggers (e.g. ["push"]).
	TrustedTriggers []string

	// RequireGitHubHosted requires the build to run on GitHub-hosted runners.
	RequireGitHubHosted bool

	// GitHubToken is a read-only token for calling the GitHub attestations API.
	GitHubToken string
}

// PolicyFromEnv loads attestation policy from environment variables.
func PolicyFromEnv() Policy {
	p := Policy{
		TrustedRepo:         "Layr-Labs/d-inference",
		TrustedWorkflow:     ".github/workflows/release.yml",
		TrustedTriggers:     []string{"push"},
		RequireGitHubHosted: true,
	}

	if v := os.Getenv("ATTESTATION_REQUIRED"); v == "true" || v == "1" {
		p.Required = true
	}

	if v := os.Getenv("TRUSTED_REPO"); v != "" {
		p.TrustedRepo = v
	}

	if v := os.Getenv("TRUSTED_WORKFLOW"); v != "" {
		p.TrustedWorkflow = v
	}

	if v := os.Getenv("TRUSTED_ACTORS"); v != "" {
		p.TrustedActors = strings.Split(v, ",")
		for i := range p.TrustedActors {
			p.TrustedActors[i] = strings.TrimSpace(p.TrustedActors[i])
		}
	}

	if v := os.Getenv("TRUSTED_TRIGGERS"); v != "" {
		p.TrustedTriggers = strings.Split(v, ",")
		for i := range p.TrustedTriggers {
			p.TrustedTriggers[i] = strings.TrimSpace(p.TrustedTriggers[i])
		}
	}

	if v := os.Getenv("GITHUB_ATTESTATION_TOKEN"); v != "" {
		p.GitHubToken = v
	}

	return p
}

// Enabled returns true if attestation verification can be performed.
func (p Policy) Enabled() bool {
	return p.GitHubToken != ""
}
