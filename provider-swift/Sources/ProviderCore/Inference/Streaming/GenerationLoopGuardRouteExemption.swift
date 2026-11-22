// Copyright © 2026 Eigen Labs.

extension GenerationLoopGuardPolicy {
    /// A production route that submits rows without a loop guard, whatever
    /// `decision(_:)` says for their model type.
    ///
    /// `EngineV2Bridge.submitTokenized` defaults `loopGuard:` to nil, so a
    /// call that leaves the argument out compiles and its answers that repeat
    /// run to their cap. A route that means to pass none says so with
    /// `exempt(_:)` and one of these; every other production call passes the
    /// guard it resolved. `GenerationLoopGuardCallSiteTests` reads the sources
    /// and fails on a call that does neither.
    enum RouteExemption: CaseIterable, Sendable {
        /// A pair's image and video requests: GLM-5.3 and Qwen media, MiMo images.
        case pairMedia
        /// MiMo's own media requests on one Mac.
        case nativeMiMoMedia
        /// The managed MiMo load's decoded-media entry
        /// (`MiMoV26ServingLoad.submitDecodedMedia`).
        case mimoDecodedMedia
        /// `EngineV2Bridge.submit(request:)`: role and content messages in the
        /// engine's own request shape.
        case directSubmit
        /// Model calibration's rows (`EngineV2Bridge.runModelCalibrationCell`).
        case modelCalibration

        /// Why the route passes no guard, as far as the code records it.
        var reason: String {
            switch self {
            case .pairMedia, .nativeMiMoMedia, .mimoDecodedMedia:
                "no guard has been wired or qualified on this route; no reason against one is recorded"
            case .directSubmit:
                "no chat request or tool preparation to resolve a guard from; "
                    + "production submits only the pair warm-up's few tokens this way"
            case .modelCalibration:
                "a measurement row, not a chat answer: there is no chat request to resolve a guard from"
            }
        }
    }

    /// The loop guard of an exempt route: none.
    static func exempt(_ route: RouteExemption) -> GenerationLoopGuard? { nil }
}
