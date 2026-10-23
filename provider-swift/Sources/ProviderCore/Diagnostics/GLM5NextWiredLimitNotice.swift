import Foundation

/// Tells the operator the wired-limit fix when a GLM-5.3-Flash load or request
/// fails with a Metal out-of-memory error on a Mac below the recommendation.
/// Logged once per process: the full notice to stderr (`provider.log`, or the
/// terminal of a foreground `start`) and a fixed pointer to the unified log.
/// Error text is only matched, never logged.
public enum GLM5NextWiredLimitNotice {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reported = false

    public static func report(_ error: any Error, modelID: String) {
        report(modelID: modelID) { GLM5NextWiredLimit.isMetalOutOfMemory(error) }
    }

    /// For failures already flattened to a message, such as recorded load errors.
    static func report(failureMessage: String, modelID: String) {
        report(modelID: modelID) { GLM5NextWiredLimit.isMetalOutOfMemory(failureMessage) }
    }

    /// The notice for one failure, or nil when it does not apply.
    public static func notice(
        modelID: String, isMetalOutOfMemory: Bool,
        recommendation: GLM5NextWiredLimit.Recommendation?, limits: GLM5NextWiredLimit.Limits,
        cliName: String = BuildEnvironment.current.cliName
    ) -> String? {
        guard GLM5NextWiredLimit.isGLM5Next(modelID: modelID), isMetalOutOfMemory,
            let recommendation, !recommendation.isMet(by: limits)
        else { return nil }
        return recommendation.notice(cliName: cliName)
    }

    private static func report(modelID: String, isMetalOutOfMemory: () -> Bool) {
        guard !lock.withLock({ reported }), GLM5NextWiredLimit.isGLM5Next(modelID: modelID),
            isMetalOutOfMemory(),
            let notice = notice(
                modelID: modelID, isMetalOutOfMemory: true,
                recommendation: GLM5NextWiredLimit.recommendationForThisMac(), limits: .live())
        else { return }
        let first = lock.withLock { () -> Bool in
            defer { reported = true }
            return !reported
        }
        guard first else { return }
        FileHandle.standardError.write(Data("WARN: \(notice)\n".utf8))
        ProviderLogger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "glm")
            .warning(.glmWiredLimitNotice)
    }
}
