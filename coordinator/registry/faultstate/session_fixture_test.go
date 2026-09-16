package faultstate

import "github.com/eigeninference/d-inference/coordinator/attestation"

// These unit fixtures bind explicit identity strings to real owner sessions.
// Registry's attestation, Provider-lock and reservation contracts are exercised
// by the integration tests that remain in registry.
func attachTestSession(r *testManager, id string) *Session[string] {
	p := &Session[string]{}
	r.Attach(p, id, id)
	return p
}
func attachTestIdentity(r *testManager, id, key string) *Session[string] {
	p := attachTestSession(r, id)
	r.Bind(p, key, "")
	return p
}
func attachTestVersion(r *testManager, id, key, version string) *Session[string] {
	p := attachTestIdentity(r, id, key)
	noteTestVersion(r, p, version)
	return p
}
func bindTestIdentity(r *testManager, p *Session[string], identity *attestation.VerificationResult) {
	key := ""
	if identity != nil && identity.Valid {
		if identity.SerialNumber != "" {
			key = "serial:" + identity.SerialNumber
		} else if identity.PublicKey != "" {
			key = "sekey:" + identity.PublicKey
		}
	}
	r.Bind(p, key, r.versions[p])
}
func noteTestVersion(r *testManager, p *Session[string], version string) {
	if r.versions == nil {
		r.versions = make(map[*Session[string]]string)
	}
	r.versions[p] = version
	r.NoteVersion(p, version)
}
func detachTestSession(r *testManager, id string) {
	p := r.sessions[id]
	key := r.FaultKeyForSession(id)
	if key == id {
		key = ""
	}
	r.Detach(p, key)
}

const versionResetSerial = "SER-UPGRADE"
const versionResetStable = "serial:" + versionResetSerial

func attachTestVersionFirst(r *testManager, id, key, version string) *Session[string] {
	p := attachTestSession(r, id)
	noteTestVersion(r, p, version)
	r.Bind(p, key, version)
	return p
}
func faultKeyOf(r *testManager, id string) string { return r.FaultKeyForSession(id) }
