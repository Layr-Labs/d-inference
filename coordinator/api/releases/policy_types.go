package releases

type approvedReleasePolicy struct {
	Version        string
	Platform       string
	Backend        string
	BinaryHash     string
	MetallibHash   string
	TemplateHashes map[string]string
}

type releaseTrustPolicySnapshot struct {
	Generation   uint64
	Required     bool
	ByBinaryHash map[string][]approvedReleasePolicy
}
