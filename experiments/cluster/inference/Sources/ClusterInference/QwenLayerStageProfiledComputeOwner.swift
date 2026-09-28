import MLX

/// Partial-construction/callback failures retire the fresh owner before any
/// context can escape. Cleanup does not call the potentially expired deadline.
func makeQwenLayerStageProfiledComputeOwner(loaded: LoadedQwenLayerStage,
    admission: QwenLayerStageProfiledComputeAdmission, check: () throws -> Void
) throws -> QwenLayerStageSession {
    var owned: QwenLayerStageSession?
    do {
        return try MLX.withError { error in
            try error.check(); try check(); try error.check()
            let fresh = try QwenLayerStageSession(stage: loaded, plan: admission.local.plan,
                profiledRequest: admission.local.request.request)
            owned = fresh
            try error.check(); try check(); try error.check()
            guard fresh.committedTokens == 0, !fresh.isClosed, !fresh.isFailed,
                  fresh.identity.stageIndex == admission.stageIndex,
                  fresh.identity.requestFingerprint == admission.local.request.request.fingerprint,
                  fresh.identity.activationDType == "bfloat16" else {
                throw ProbeError("Profiled compute did not acquire the exact fresh local stage owner")
            }
            return fresh
        }
    } catch {
        let primary = error
        if let owned {
            do { try MLX.withError { fault in try owned.cancel(); try fault.check() } }
            catch { throw ProbeError("Profiled compute initialization failed (\(primary)); retirement also failed (\(error))") }
            guard owned.isClosed, owned.isFailed else {
                throw ProbeError("Profiled compute initialization failed (\(primary)); request owner remained live")
            }
        }
        throw primary
    }
}
