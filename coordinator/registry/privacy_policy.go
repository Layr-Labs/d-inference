package registry

func providerSupportsPrivateTextLocked(p *Provider) bool {
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks {
		return false
	}
	if !p.RuntimeManifestChecked {
		return false
	}
	// Require coordinator-verified SIP (from attestation challenge) rather
	// than trusting the provider's self-reported SIPEnabled field.
	if !p.ChallengeVerifiedSIP {
		return false
	}
	caps := p.PrivacyCapabilities
	if caps == nil {
		return false
	}
	// Only mlx-swift is routable (enforced by privateTextBackendSupported above).
	// Python-specific caps (PythonRuntimeLocked, DangerousModulesBlocked) are
	// retained in the protocol struct for wire backward compat but are no longer
	// required for routing.
	return caps.TextBackendInprocess &&
		caps.TextProxyDisabled &&
		caps.AntiDebugEnabled &&
		caps.CoreDumpsDisabled &&
		caps.EnvScrubbed
}

func privateTextBackendSupported(backend string) bool {
	// Python/legacy inprocess-mlx backend is deprecated and no longer
	// routable. Only Swift (mlx-swift) providers are admitted.
	return backend == BackendMLXSwift
}
