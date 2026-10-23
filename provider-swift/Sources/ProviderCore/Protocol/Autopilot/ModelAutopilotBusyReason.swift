import Foundation

/// Closed vocabulary of `busy_reason(s)` and the `provider_busy` status
/// `detail`. Declaration order is report order: an owner precedes the work it
/// owns, so the first reason names the outermost cause.
public enum ModelAutopilotBusyReason: String, CaseIterable, Sendable {
    /// Another accepted operation owns residency. Reported, never an input to
    /// the operation policy's busy check.
    case autopilotOperation = "autopilot_operation"
    case shuttingDown = "shutting_down"
    /// Update, lifecycle, model-switch or reconnect drain.
    case draining
    case reconnectAfterRetirement = "reconnect_after_retirement"
    case modelSwitch = "model_switch"
    case revisionActivation = "revision_activation"
    case revisionUpdate = "revision_update"
    case startupPreload = "startup_preload"
    /// A coordinator `load_model` preload.
    case preload
    case engineRecovery = "engine_recovery"
    case mtpUpgrade = "mtp_upgrade"
    case mtpStaging = "mtp_staging"
    /// A verified build is being hashed or published.
    case modelAdvertisement = "model_advertisement"
    /// A verified build is between its reserve raise and its advertisement.
    case pendingAdvertisement = "pending_advertisement"
    /// The provider-wide load gate is held.
    case loadGate = "load_gate"
    case modelLoading = "model_loading"
    case reslice
    case modelUnloading = "model_unloading"
    /// A failed self-test is retiring a build.
    case modelRetiring = "model_retiring"
    /// Native memory has not been proven released.
    case nativeMemoryRetained = "native_memory_retained"
    /// Accepted network or local requests are in flight.
    case inflightWork = "inflight_work"
}

/// Closed vocabulary of `transition_stalls[].transition`: the bounded
/// transitional states the provider watchdog supervises.
public enum ModelAutopilotTransition: String, CaseIterable, Sendable {
    case autopilotOperation = "autopilot_operation"
    case startupPreload = "startup_preload"
    case preload
    case modelLoading = "model_loading"
    case modelAdvertisement = "model_advertisement"
    case modelSwitch = "model_switch"
    case reslice
    case reconnectAfterRetirement = "reconnect_after_retirement"
}
