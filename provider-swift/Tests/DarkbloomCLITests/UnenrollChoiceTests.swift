import ArgumentParser
import Testing
@testable import darkbloom

@Suite struct UnenrollChoiceTests {
    private func command(_ arguments: [String] = []) throws -> Unenroll {
        try #require(try Darkbloom.parseAsRoot(["unenroll"] + arguments) as? Unenroll)
    }

    @Test func plainUnenrollOffersProfileRemovalWithoutAFlag() async throws {
        let command = try command()
        var output: [String] = []
        let mode = try command.chooseUnenrollmentMode(
            isInteractive: true, osMajor: 27, readInput: { "2" }, writeLine: { output.append($0) })
        #expect(mode == .removeRetiredProfile)
        #expect(output.contains { $0.contains("Fully exit Darkbloom") })
        #expect(output.contains { $0.contains("Remove only the Darkbloom MDM profile") && $0.contains("keep the provider") })
        #expect(!output.contains { $0.contains("cannot serve") })
        #expect(output.contains { $0.contains("no longer uses its MDM profile") && $0.contains("App Attest") })
        #expect(!output.contains { $0.contains("coordinator approval") })
        var operations: [String] = []
        try await Unenroll.performUnenrollment(
            mode: mode, stopProvider: { operations.append("stop") },
            leave: { operations.append("cleanup") }, removeProfile: { operations.append("profile") })
        #expect(operations == ["profile"])
    }

    /// On older macOS the menu says, before the choice, that removing the
    /// profile does not make the Mac serve.
    @Test func olderMacOSHearsItCannotServeBeforeChoosing() throws {
        var output: [String] = []
        var asked = false
        let mode = try command().chooseUnenrollmentMode(
            isInteractive: true, osMajor: 26, readInput: { asked = true; return "2" },
            writeLine: { line in if !asked { output.append(line) } })
        #expect(mode == .removeRetiredProfile)
        #expect(output.contains { $0.contains("macOS 26 and cannot serve") && $0.contains("does not change that") })
    }

    @Test func fullExitStopsBeforeOfferingCleanup() async throws {
        let mode = try command().chooseUnenrollmentMode(isInteractive: true, readInput: { "1" }, writeLine: { _ in })
        var operations: [String] = []
        try await Unenroll.performUnenrollment(
            mode: mode, stopProvider: { operations.append("stop") },
            leave: { operations.append("cleanup") }, removeProfile: { operations.append("profile") })
        #expect(operations == ["stop", "cleanup"])
    }

    @Test func emptyOrClosedInputNeverStopsOrCleansAnything() async throws {
        for input: String? in [nil, "", " \n"] {
            let mode = try command().chooseUnenrollmentMode(
                isInteractive: true, readInput: { input }, writeLine: { _ in })
            #expect(mode == .cancel)
            var operations: [String] = []
            try await Unenroll.performUnenrollment(
                mode: mode, stopProvider: { operations.append("stop") },
                leave: { operations.append("cleanup") }, removeProfile: { operations.append("profile") })
            #expect(operations.isEmpty)
        }
    }

    @Test func invalidInputCannotSelectDestructiveExit() throws {
        var answers = ["yes", " 2 "]
        var output: [String] = []
        let mode = try command().chooseUnenrollmentMode(
            isInteractive: true, readInput: { answers.removeFirst() },
            writeLine: { output.append($0) })
        #expect(mode == .removeRetiredProfile)
        #expect(output.contains { $0.contains("No changes have been made") })
    }

    @Test func noninteractiveInvocationNeedsExplicitIntent() throws {
        #expect(throws: ValidationError.self) {
            try command().chooseUnenrollmentMode(isInteractive: false)
        }
        #expect(try command(["--force"]).chooseUnenrollmentMode(isInteractive: false) == .fullExit)
        #expect(try command(["--keep-serving"]).chooseUnenrollmentMode(isInteractive: false) == .removeRetiredProfile)
        let contradictory = try command(["--keep-serving", "--force"])
        #expect(throws: ValidationError.self) {
            try contradictory.chooseUnenrollmentMode(isInteractive: true)
        }
    }

    private enum Failure: Error { case expected }

    @Test func failedStopNeverReachesCleanup() async {
        var operations: [String] = []
        do {
            try await Unenroll.performUnenrollment(
                mode: .fullExit,
                stopProvider: { operations.append("stop"); throw Failure.expected },
                leave: { operations.append("cleanup") }, removeProfile: { operations.append("profile") })
            Issue.record("Expected stop failure")
        } catch {}
        #expect(operations == ["stop"])
    }

    @Test func failedProfileGuidanceNeverFallsBackToExit() async {
        var operations: [String] = []
        do {
            try await Unenroll.performUnenrollment(
                mode: .removeRetiredProfile, stopProvider: { operations.append("stop") },
                leave: { operations.append("cleanup") },
                removeProfile: { operations.append("profile"); throw Failure.expected })
            Issue.record("Expected profile guidance failure")
        } catch {}
        #expect(operations == ["profile"])
    }
}
