import ArgumentParser
import Testing
@testable import darkbloom

@Suite struct UnenrollChoiceTests {
    private func command(_ arguments: [String] = []) throws -> Unenroll {
        try #require(try Darkbloom.parseAsRoot(["unenroll"] + arguments) as? Unenroll)
    }

    @Test func plainUnenrollOffersAppAttestWithoutAFlag() async throws {
        let command = try command()
        var output: [String] = []
        let mode = try command.chooseUnenrollmentMode(
            isInteractive: true, osMajor: 27,
            readInput: { "2" }, writeLine: { output.append($0) })
        #expect(mode == .appAttest)
        #expect(output.contains { $0.contains("Fully exit Darkbloom") })
        #expect(output.contains { $0.contains("Remove only Darkbloom MDM") })
        #expect(output.contains { $0.contains("macOS 27 or later") && $0.contains("coordinator approval") })
        var operations: [String] = []
        try await Unenroll.performUnenrollment(
            mode: mode, stopProvider: { operations.append("stop") },
            leave: { operations.append("cleanup") }, migrate: { operations.append("migrate") })
        #expect(operations == ["migrate"])
    }

    @Test func fullExitStopsBeforeOfferingCleanup() async throws {
        let mode = try command().chooseUnenrollmentMode(
            isInteractive: true, osMajor: 26, readInput: { "1" }, writeLine: { _ in })
        var operations: [String] = []
        try await Unenroll.performUnenrollment(
            mode: mode, stopProvider: { operations.append("stop") },
            leave: { operations.append("cleanup") }, migrate: { operations.append("migrate") })
        #expect(operations == ["stop", "cleanup"])
    }

    @Test func emptyOrClosedInputNeverStopsOrCleansAnything() async throws {
        for input: String? in [nil, "", " \n"] {
            let mode = try command().chooseUnenrollmentMode(
                isInteractive: true, osMajor: 27, readInput: { input }, writeLine: { _ in })
            #expect(mode == .cancel)
            var operations: [String] = []
            try await Unenroll.performUnenrollment(
                mode: mode, stopProvider: { operations.append("stop") },
                leave: { operations.append("cleanup") }, migrate: { operations.append("migrate") })
            #expect(operations.isEmpty)
        }
    }

    @Test func invalidInputCannotSelectDestructiveExit() throws {
        var answers = ["yes", " 2 "]
        var output: [String] = []
        let mode = try command().chooseUnenrollmentMode(
            isInteractive: true, osMajor: 28, readInput: { answers.removeFirst() },
            writeLine: { output.append($0) })
        #expect(mode == .appAttest)
        #expect(output.contains { $0.contains("No changes have been made") })
    }

    @Test func oldMacCannotEnterMigrationThroughEitherEntryPoint() throws {
        let plain = try command()
        #expect(throws: ValidationError.self) {
            try plain.chooseUnenrollmentMode(
                isInteractive: true, osMajor: 26, readInput: { "2" }, writeLine: { _ in })
        }
        let direct = try command(["--keep-serving"])
        #expect(throws: ValidationError.self) {
            try direct.chooseUnenrollmentMode(isInteractive: false, osMajor: 26)
        }
        // The OS guard must precede real configuration, profile and key reads.
        #expect(throws: ValidationError.self) { try direct.prepareMDMRemovalWhileServing(osMajor: 26) }
    }

    @Test func noninteractiveInvocationNeedsExplicitIntent() throws {
        let plain = try command()
        #expect(throws: ValidationError.self) {
            try plain.chooseUnenrollmentMode(isInteractive: false, osMajor: 27)
        }
        #expect(try command(["--force"]).chooseUnenrollmentMode(isInteractive: false, osMajor: 26) == .fullExit)
        #expect(try command(["--keep-serving"]).chooseUnenrollmentMode(isInteractive: false, osMajor: 27) == .appAttest)
        let contradictory = try command(["--keep-serving", "--force"])
        #expect(throws: ValidationError.self) {
            try contradictory.chooseUnenrollmentMode(isInteractive: true, osMajor: 27)
        }
    }

    private enum Failure: Error { case expected }

    @Test func failedStopNeverReachesCleanup() async {
        var operations: [String] = []
        do {
            try await Unenroll.performUnenrollment(
                mode: .fullExit,
                stopProvider: { operations.append("stop"); throw Failure.expected },
                leave: { operations.append("cleanup") }, migrate: { operations.append("migrate") })
            Issue.record("Expected stop failure")
        } catch {}
        #expect(operations == ["stop"])
    }

    @Test func failedMigrationNeverFallsBackToExit() async {
        var operations: [String] = []
        do {
            try await Unenroll.performUnenrollment(
                mode: .appAttest, stopProvider: { operations.append("stop") },
                leave: { operations.append("cleanup") },
                migrate: { operations.append("migrate"); throw Failure.expected })
            Issue.record("Expected migration failure")
        } catch {}
        #expect(operations == ["migrate"])
    }
}
