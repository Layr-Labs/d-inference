package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

type (
	AppAttestArchiveStore          = contracts.AppAttestArchiveStore
	AppAttestDecision              = contracts.AppAttestDecision
	AppAttestEnrollment            = contracts.AppAttestEnrollment
	AppAttestEnrollmentStore       = contracts.AppAttestEnrollmentStore
	AppAttestEvent                 = contracts.AppAttestEvent
	AppAttestEvidence              = contracts.AppAttestEvidence
	AppAttestMaintenanceStore      = contracts.AppAttestMaintenanceStore
	AppAttestReadiness             = contracts.AppAttestReadiness
	AppAttestReadinessStore        = contracts.AppAttestReadinessStore
	AppAttestReceipt               = contracts.AppAttestReceipt
	AppAttestReceiptStore          = contracts.AppAttestReceiptStore
	AppAttestShadowKey             = contracts.AppAttestShadowKey
	AppAttestShadowStore           = contracts.AppAttestShadowStore
	MachineIdentity                = contracts.MachineIdentity
	MachineIdentityLookupStore     = contracts.MachineIdentityLookupStore
	MachineInventoryBackfillStore  = contracts.MachineInventoryBackfillStore
	MachineInventoryReconcileStore = contracts.MachineInventoryReconcileStore
	MachineInventoryStore          = contracts.MachineInventoryStore
	MachineObservation             = contracts.MachineObservation
)
