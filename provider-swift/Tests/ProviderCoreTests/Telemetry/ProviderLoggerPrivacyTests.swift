import Foundation
import Testing
@testable import ProviderCore

private final class ProviderLogRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let level: ProviderLogLevel
        let visibility: ProviderLogVisibility
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(level: ProviderLogLevel, visibility: ProviderLogVisibility, message: String) {
        lock.withLock {
            entries.append(Entry(level: level, visibility: visibility, message: message))
        }
    }

    func snapshot() -> [Entry] {
        lock.withLock { entries }
    }
}

@Test func providerLoggerKeepsStringsPrivateAndTypedMessagesPublic() {
    let recorder = ProviderLogRecorder()
    let logger = ProviderLogger(
        subsystem: "test",
        category: "privacy",
        sink: { level, visibility, message in
            recorder.append(level: level, visibility: visibility, message: message)
        }
    )

    let secret = "request=req-secret url=https://private.invalid model=user/model error=raw"
    logger.warning(secret)
    logger.info(.coordinatorConnected)

    #expect(recorder.snapshot() == [
        .init(level: .warning, visibility: .private, message: secret),
        .init(
            level: .info,
            visibility: .public,
            message: ProviderOperationalMessage.coordinatorConnected.rawValue
        ),
    ])
}

@Test func inferenceFailurePublishesOnlyItsClosedCategory() {
    let recorder = ProviderLogRecorder()
    let logger = ProviderLogger(
        subsystem: "test",
        category: "privacy",
        sink: { level, visibility, message in
            recorder.append(level: level, visibility: visibility, message: message)
        }
    )

    InferenceFailureLogger(logger: logger).record(
        requestId: "private-request-id",
        failure: InferenceFailure(
            code: .generationFailure,
            statusCode: 500,
            errorReason: .jinjaTemplate
        )
    )

    let entries = recorder.snapshot()
    #expect(entries.first == .init(
        level: .error,
        visibility: .public,
        message: ProviderOperationalMessage.inferenceFailureGeneration.rawValue
    ))
    #expect(entries.dropFirst().allSatisfy { $0.visibility == .private })
    #expect(entries.first?.message.contains("private-request-id") == false)
    #expect(entries.first?.message.contains("jinja_template") == false)
}

@Test func refusalPublishesOnlyItsFixedReason() {
    let recorder = ProviderLogRecorder()
    let logger = ProviderLogger(
        subsystem: "test",
        category: "privacy",
        sink: { level, visibility, message in
            recorder.append(level: level, visibility: visibility, message: message)
        }
    )

    InferenceFailureLogger(logger: logger).record(
        requestId: "private-request-id",
        failure: InferenceFailure(code: .invalidRequest, statusCode: 400, refusal: .unsupportedReasoningControl)
    )

    #expect(recorder.snapshot() == [
        .init(
            level: .error,
            visibility: .public,
            message: ProviderOperationalMessage.refusalUnsupportedReasoningControl.rawValue
        ),
        .init(
            level: .error,
            visibility: .private,
            message: "[private-request-id] inference failure code=invalid_request status=400"
                + " refusal=unsupported_reasoning_control"
        ),
    ])
}

@Test func publicProviderLogVocabularyIsFixedBoundedText() {
    let messages = ProviderOperationalMessage.allCases.map(\.rawValue)

    #expect(Set(messages).count == messages.count)
    #expect(messages.allSatisfy { !$0.isEmpty && $0.utf8.count <= 96 })
    #expect(messages.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
}

@Test func publicProviderLogNamesThisBuildsCommand() {
    #expect(ProviderOperationalMessage.startupPreloadInsufficientMemory.text
        == "Startup preload skipped: low free memory. Run \(BuildEnvironment.current.cliName) status or doctor.")
    for message in ProviderOperationalMessage.allCases {
        #expect(!message.text.contains("{"))
    }
}

/// A single Mac's update steps are public fixed lines at the level unified logging keeps on disk; the progress lines
/// beside them are private info lines, which unified logging keeps only in memory.
@Test func autoUpdateStepsArePublicNoticeLinesOfTheirOwn() {
    let recorder = ProviderLogRecorder()
    let logger = ProviderLogger(subsystem: "test", category: "loop", sink: { level, visibility, message in
        recorder.append(level: level, visibility: visibility, message: message)
    })
    for step in AutoUpdateController.Step.allCases { logger.notice(ProviderLoop.autoUpdateNotice(step)) }
    let entries = recorder.snapshot()
    #expect(entries.count == AutoUpdateController.Step.allCases.count)
    #expect(entries.allSatisfy { $0.level == .notice && $0.visibility == .public })
    #expect(Set(entries.map(\.message)).count == entries.count, "each step has its own line")
    #expect(entries.allSatisfy { $0.message.hasPrefix("Auto-update") })
    #expect(ProviderLoop.autoUpdateNotice(.restarting).text == "Auto-update: new release installed; restarting into it")
}
