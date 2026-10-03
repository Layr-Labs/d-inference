package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// After a scrub the in-memory MDM scheduler must not keep the erased
// account's UDIDs or jobs; other keys stay.
func TestMDMSchedulerForgetDropsErasedKeys(t *testing.T) {
	srv, _ := testServer(t)
	sch := newMDMVerificationScheduler(srv, MDMSchedulerConfig{}, mdmSchedulerDeps{})
	erased := verificationSchedulerKey("se-erased", store.VerificationTaskSecurityInfo)
	kept := verificationSchedulerKey("se-kept", store.VerificationTaskSecurityInfo)
	sch.jobs[erased] = &mdmScheduledJob{record: store.VerificationJob{SEPubKey: "se-erased", UDID: "udid-erased"}}
	sch.jobs[kept] = &mdmScheduledJob{record: store.VerificationJob{SEPubKey: "se-kept", UDID: "udid-kept"}}
	sch.byUDID["udid-erased"], sch.byUDID["udid-kept"] = erased, kept
	sch.bindings["se-erased"] = &mdmLiveBinding{}

	sch.Forget([]string{"se-erased"})

	if _, ok := sch.jobs[erased]; ok {
		t.Fatal("erased job kept")
	}
	if _, ok := sch.byUDID["udid-erased"]; ok {
		t.Fatal("erased UDID route kept")
	}
	if _, ok := sch.bindings["se-erased"]; ok {
		t.Fatal("erased binding kept")
	}
	if sch.jobs[kept] == nil || sch.byUDID["udid-kept"] != kept {
		t.Fatal("Forget removed another key")
	}
	var nilScheduler *mdmVerificationScheduler
	nilScheduler.Forget([]string{"se-erased"})
}

func TestTrustReuseCacheForget(t *testing.T) {
	c := newTrustReuseCache()
	c.records["se-erased"] = trustReuseRecord{serial: "SERIAL", mdaUDID: "UDID"}
	c.records["se-kept"] = trustReuseRecord{serial: "OTHER"}
	c.forget([]string{"se-erased"})
	if _, ok := c.records["se-erased"]; ok {
		t.Fatal("erased record kept")
	}
	if _, ok := c.records["se-kept"]; !ok {
		t.Fatal("forget removed another key")
	}
	var nilCache *trustReuseCache
	nilCache.forget([]string{"x"})
}
