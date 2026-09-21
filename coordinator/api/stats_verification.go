package api

import (
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Counts refer to public connections in this snapshot. A dual-path connection
// contributes once to Authorized, once to each method, and once to Overlap.
type verificationMethodCounts struct {
	Connections int `json:"connections"`
	Authorized  int `json:"authorized"`
	AppAttest   int `json:"app_attest"`
	Legacy      int `json:"legacy"`
	Overlap     int `json:"overlap"`
}

type verificationCounts struct {
	verificationMethodCounts
	KnownMachines   int `json:"known_unique_machines"`
	UnknownMachines int `json:"connections_without_machine_identity"`
	ReportedMacOS27 int `json:"reported_macos_27_or_later"`
	ReportedOS      int `json:"connections_with_reported_os"`
}

func (c *verificationMethodCounts) add(v registry.Verification) {
	c.Connections++
	if v.Method() != "none" {
		c.Authorized++
	}
	if v.AppAttest.State == "verified" {
		c.AppAttest++
	}
	if v.Legacy.State == "verified" {
		c.Legacy++
	}
	if v.Method() == "dual" {
		c.Overlap++
	}
}

func reportedOSVersion(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.AttestationResult == nil {
		return ""
	}
	return p.AttestationResult.OSVersion
}

// addProvider is called in the same fleet walk that produces public rows, so
// the denominator cannot change halfway through constructing a response.
func (c *verificationCounts) addProvider(p *registry.Provider, v registry.Verification, machines map[[2]string]struct{}) {
	c.add(v)
	account, machine := p.GetVerifiedMachineIdentity()
	if account != "" && machine != "" {
		machines[[2]string{account, machine}] = struct{}{}
	} else {
		c.UnknownMachines++
	}
	c.KnownMachines = len(machines)
	os := reportedOSVersion(p)
	if os != "" {
		c.ReportedOS++
	}
	major, err := strconv.Atoi(strings.Split(os, ".")[0])
	if err == nil && major >= 27 {
		c.ReportedMacOS27++
	}
}
