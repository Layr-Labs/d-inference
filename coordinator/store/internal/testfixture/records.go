package testfixture

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func SeedUser(t *testing.T, st contracts.Store, accountID string) *contracts.User {
	t.Helper()
	u := &contracts.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Email: accountID + "@example.test"}
	if err := st.CreateUser(u); err != nil {
		t.Fatalf("CreateUser(%s): %v", accountID, err)
	}
	return u
}

func Int64(v int64) *int64 { return &v }

func Int(v int) *int { return &v }

func Bool(v bool) *bool { return &v }

// canonicalJSON re-encodes raw with sorted keys and no whitespace so a JSONB
// round trip (which normalises both) compares equal. Empty stays nil.
func CanonicalJSON(t *testing.T, raw json.RawMessage) json.RawMessage {
	t.Helper()
	if len(raw) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("invalid JSON %q: %v", raw, err)
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	return b
}

func NormalizeProfile(t *testing.T, r contracts.RequestProfileRecord) contracts.RequestProfileRecord {
	t.Helper()
	r.ReceivedAt = r.ReceivedAt.UTC().Truncate(time.Microsecond)
	r.CreatedAt = r.CreatedAt.UTC().Truncate(time.Microsecond)
	r.GateRejections = CanonicalJSON(t, r.GateRejections)
	r.Candidates = CanonicalJSON(t, r.Candidates)
	r.ProviderProfile = CanonicalJSON(t, r.ProviderProfile)
	return r
}

func NormalizeSnapshot(t *testing.T, f contracts.FleetSnapshotRow) contracts.FleetSnapshotRow {
	t.Helper()
	f.SampledAt = f.SampledAt.UTC().Truncate(time.Microsecond)
	f.QueueDepthByModel = CanonicalJSON(t, f.QueueDepthByModel)
	return f
}

// fullProfile fills every field with a distinctive value so a round trip
// exercises every column. Pointer fields mix nil, pointer-to-zero and
// pointer-to-value; non-pointer zero values are left at zero deliberately.
func FullProfile(requestID string, attempt int, at time.Time) *contracts.RequestProfileRecord {
	return &contracts.RequestProfileRecord{
		CoordRequestID: "coord-" + requestID, RequestID: requestID, Attempt: attempt,
		BackupOf: "", Winning: true, Endpoint: "POST /v1/chat/completions", Stream: true,
		Model: "qwen3-30b", PublicModel: "qwen", ProviderID: "prov-a", ProviderVersion: "0.8.13",
		ChipFamily: "m3", KVBackend: "paged", FinalStatus: "ok", ErrorReason: "", TerminalCause: "complete",
		ClientOutcome: "done", ProviderOutcome: "complete", ClientGonePhase: "", FirstContentBudgetMs: 4000,
		AdmissionMode: "hard", PredictiveBypass: "none", ReservationTTFTCeilingMs: Float64(3500.5), DispatchBudgetMs: Int64(3401), EstimatedPromptTokens: 1500, RequestedMaxTokens: 512, RequiresVision: true, HasTools: true,
		ReceivedAt: at.Add(-time.Second),

		AuthDoneUS: Int64(10), RatelimitDoneUS: Int64(20), SealedOpenUS: nil, HandlerEntryUS: Int64(0),
		ParsedUS: Int64(40), ReservedUS: Int64(50), MediaFetchedUS: nil, PreflightDoneUS: Int64(70),
		PlanDoneUS: Int64(80), AttemptStartUS: Int64(90), ReserveLockAcquiredUS: Int64(91), ReserveDoneUS: Int64(92),
		QueuedUS: nil, DequeuedUS: nil, TopupDoneUS: Int64(100), EncryptedUS: Int64(110),
		WriteSubmittedUS: Int64(120), WriteDequeuedUS: Int64(121), WriteDoneUS: Int64(122), AcceptedUS: Int64(130),
		FirstChunkIngressUS: Int64(200), FirstChunkDequeuedUS: Int64(201), FirstContentIngressUS: Int64(210),
		FirstContentUS: Int64(211), HeadersWrittenUS: Int64(212), FirstFlushUS: Int64(213), LastFlushUS: Int64(900),
		ClientGoneUS: nil, CancelSentUS: nil, CompleteIngressUS: Int64(950), DoneFlushedUS: Int64(960),
		FinalizedUS: Int64(970), SettleDBUS: Int64(5), DBUS: Int64(0), DBCalls: 3,

		BodyBytes: 1234, SealedBodyBytes: 1300, AuthKind: "api_key", AuthDBRead: true, ReserveMode: "ttft",
		MediaItems: 0, MediaBytes: 0, PreflightOutcome: "pass", PlanOutcome: "single", ChunksIn: 40, ChunksOut: 39,
		BytesOut: 8192, DecryptUSTotal: 300, MaxChunkGapUS: 45000, HeldPreambleChunks: 1, ClientWriteErr: false,
		AttemptsTotal: 1, FailedAttempts: 0, FailedAttemptsUS: 0, BackupLaunched: false, BackupWon: false,
		TransportEstUS: Int64(15000), SleptUS: nil, TimingAnomaly: false,

		CandidateSetSize: 12, Scanned: 12, GateRejections: json.RawMessage(`{"offline": 2, "breaker": 1}`),
		RunnerUpProviderID: "prov-b", RunnerUpCostMs: 812.5, NearTiePoolSize: 2, SelectionPath: "unique_min",
		BestIdleProviderID: "prov-c", BestIdleTTFTMs: 400.25, PredictedTTFTMs: 350.5, RawTTFTMs: 300.75,
		PredictedDecodeTPS: 55.5, SnapshotAgeMs: 900, PendingForModel: 2, TotalPending: 7,
		CapacityRateMs: 12.5, CacheDiscountMs: 0, ShadowWouldShed: Bool(false), ShadowIdleAlternative: nil,
		LockWaitUS: 12, ScanUS: 34, AdmitUS: 56, PreflightUS: 78, TTFTCalibrationRatio: 1.1, PrefillDecodeRatio: 0.4,
		QueuePositionAtEnqueue: 0, QueueDepthAtEnqueue: 0, DrainTrigger: "",
		Candidates: json.RawMessage(`[{"provider_id":"prov-a","cost_ms":800.5},{"provider_id":"prov-b","cost_ms":812.5}]`),

		ProvTotalUS: Int64(700000), ProvFirstDeltaUS: Int64(150000), ProvEngineSubmitUS: Int64(100), ProvEngineAdmittedUS: Int64(200),
		ProvPromptPrepUS: Int64(3000), ProvLoadWaitUS: nil, ProvLoadCold: Bool(false), ProvRunningAtAdmit: Int(0),
		ProvWaitingAtAdmit: Int(2), ProvKVBytesInUseAtAdmit: Int64(1 << 30), ProvCancelStage: "",
		EngQueueWaitNS: Int64(1000), EngFirstTokenNS: Int64(150000000), EngPromptComputedNS: Int64(120000000),
		EngPrefillChunks: Int(3), EngDecodeSteps: Int(39), EngMTPAccepted: nil, EngFinishReason: "stop",
		ProviderProfile: json.RawMessage(`{"version":1,"engine":{"steps":39}}`), ProviderProfileValid: true,
		ProviderProfileInvalidReason: "", ProviderProfileConsistent: Bool(true),

		CreatedAt: at,
	}
}

func FullSnapshot(providerID, model string, at time.Time) contracts.FleetSnapshotRow {
	return contracts.FleetSnapshotRow{
		SampledAt: at, ProviderID: providerID, Model: model, EligibilityReason: "eligible", SlotState: "running",
		NumRunning: 2, NumWaiting: 1, QueuedPrefillTokens: 4096, PartialPrefillRows: 1,
		ActiveTokenBudgetUsed: 20000, ActiveTokenBudgetMax: 65536, KVBytesInUse: 3 << 30, KVBytesCapacity: 8 << 30,
		ObservedDecodeTPS: 42.5, ObservedPrefillTPS: 1800.25, IsolatedPrefillTPS: 2200, EWMAInitialized: Bool(true),
		MaxConcurrency: 4, PendingCount: 3, EffectiveCap: 4,
		CooldownActive: false, BreakerOpen: false, ClampActive: true, Ejected: false,
		GPUMemoryActiveGB: 30.5, GPUMemoryPeakGB: 33.25, FreeForLoadGB: Float64(12), MemoryPressure: 0.6, CPUUsage: 0.2,
		ThermalState: "nominal", LowPowerMode: Bool(false), MemoryPressureLevel: "normal",
		StepsExecuted: 100000, StepWallNSTotal: 5e12, DecodeRowsTotal: 250000, PrefillTokensTotal: 9000000,
		MTPRoundsTotal: 5000, MTPProposedTotal: 10000, MTPAcceptedTotal: 7000,
		HeartbeatAgeMs: 1200, WedgeSuspected: false, EvalInFlightMs: 0,
		RequestsServed: 1234, TokensGenerated: 456789, CancellationsReceived: 12, CancellationsBeforeOutput: 3,
		CancellationsPartialComplete: 9, GenerationErrorsAfterOutput: 1, ChunkEncryptionErrors: 0,
		StreamClosedWithoutTerminal: 2, CancelDuringModelLoad: 0, UsageGaps: 1,
		CancelStagePreAcceptTotal: 1, CancelStagePreEngineTotal: 2, CancelStagePrefillTotal: 3, CancelStageDecodeTotal: 4,
		CancelStagePostTerminalTotal: 2, TokensAfterCancelTotal: 40, CancelAbortNSSum: 9e9,
		ProviderVersion: "0.8.13", ModelVision: true, TemplateRenderOK: Bool(true),
	}
}

func CoordinatorSnapshot(at time.Time) contracts.FleetSnapshotRow {
	return contracts.FleetSnapshotRow{
		SampledAt: at, ProviderID: "coordinator", EligibilityReason: "", SlotState: "",
		QueueDepthTotal: 5, QueueDepthByModel: json.RawMessage(`{"qwen3-30b": 3, "gemma4-26b": 2}`),
		InflightRequests: 17, ReserveLockWaitP95US: 850, ProfileSinkDepth: 12, ProfileSinkDroppedTotal: 0,
		RouteSinkDroppedTotal: 4, UnknownRequestFramesTotal: 1, Goroutines: 412,
	}
}

func Float64(v float64) *float64 { return &v }
