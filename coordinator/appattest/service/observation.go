package service

import (
	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (x *Session) observe(stage, outcome string, metadata *appattest.Key) {
	x.observeWithClientDiagnostics(stage, outcome, metadata, protocol.AppAttestShadowPayload{})
}

func (x *Session) observeWithClientDiagnostics(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
	if stage != "archive" {
		x.lastOutcome = outcome
	}
	formatted := observation.Format(observation.Event{Provider: x.provider, Session: x.id, Account: x.account, Version: x.version,
		OSVersion: x.osVersion, Chip: x.chip, Stage: stage, Outcome: outcome, Serving: x.s.authorizer != nil,
		Dropped: x.integrity.Dropped(), Started: x.started, Metadata: metadata, ReadyContext: x.readyDiagnostics, PolicyFields: x.policyFields, Reply: reply})
	fields, tags := formatted.Fields, formatted.Tags
	if formatted.DurationMS != nil {
		x.s.ddHistogram("app_attest.shadow.duration_ms", *formatted.DurationMS, tags)
	}
	if metadata != nil {
		x.s.ddIncr("app_attest.shadow.metadata", []string{"result:" + formatted.MeasurementPolicy})
	}
	if x.inventory != nil {
		identity := x.inventory.Identity()
		fields["machine_id"] = identity.ID
		fields["identity_assurance"] = identity.Assurance
		if ok, err := x.inventory.RecordEvent(x.storageAdmission(), x.provider.ID, stage, outcome, fields); ok {
			if err != nil {
				x.s.ddIncr("app_attest.events.storage_failed", nil)
			}
		} else {
			fields["event_storage"] = "busy"
			x.s.ddIncr("app_attest.events.storage_failed", []string{"reason:busy"})
		}
	}
	x.s.ddIncr("app_attest.shadow.events", tags)
	x.s.emit(fields)
}

func boundedShadowLabel(s string) string {
	return observation.Label(s)
}
