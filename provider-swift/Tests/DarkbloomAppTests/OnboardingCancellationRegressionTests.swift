import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding cancellation and reentry", .timeLimit(.minutes(1)))
@MainActor
struct OnboardingCancellationRegressionTests {
    @Test("Done then cancel then EOF cannot start or overwrite a new setup", arguments: [false, true])
    func doneCancelEOF(reset: Bool) async throws {
        let model = OnboardingOperationTestFixture.model(installed: false)
        let download = AsyncThrowingStream<ModelDownloadStreamEvent, Error>.makeStream()
        let service = OnboardingOperationTestPreparation(model: model, streams: [download.stream])
        let flow = OnboardingOperationTestFixture.flow(service: service)
        await flow.runAutomaticWorkForCurrentStep()

        let doneApplied = OnboardingOperationTestGate()
        flow.setDraftChangeHandler { draft in
            if draft.downloadCompletedModelID == model.id {
                Task { await doneApplied.open() }
            }
        }
        flow.startPreparation()
        let task = try #require(flow.preparationTask)
        download.continuation.yield(.done)
        await doneApplied.wait()

        #expect(flow.goBack())
        #expect(flow.preparationPhase == .startFailed)
        #expect(flow.selectedModelID == model.id)
        #expect(flow.downloadCompletedModelID == model.id)
        #expect(flow.draft.normalizedForResume.downloadCompletedModelID == model.id)
        if reset { flow.resetForNewSetup() }
        let saved = flow.draft
        // The producer's EOF arrives after cancellation, not in the same
        // actor turn as .done. The cancelled consumer may already see nil.
        download.continuation.finish()
        await task.value

        #expect(await service.startedModelIDs.isEmpty)
        #expect(flow.draft == saved)
        #expect(flow.preparationTask == nil)
    }

    @Test("Back then Continue restores account retry and old cleanup cannot clear its replacement")
    func accountBackContinue() async throws {
        let first = AsyncThrowingStream<AccountLinkEvent, Error>.makeStream()
        let second = AsyncThrowingStream<AccountLinkEvent, Error>.makeStream()
        let runner = OnboardingOperationTestAccountRunner(streams: [first.stream, second.stream])
        let service = OnboardingOperationTestPreparation(model: OnboardingOperationTestFixture.model(installed: false))
        let flow = OnboardingOperationTestFixture.flow(step: .account, service: service, account: runner)
        let waiting = OnboardingOperationTestGate()
        flow.setDraftChangeHandler { draft in
            if draft.accountPhase == .waitingForApproval { Task { await waiting.open() } }
        }
        flow.startAccountLink()
        let oldTask = try #require(flow.accountLinkTask)
        first.continuation.yield(.code(userCode: "FIRST", verificationURI: "https://example.invalid", expiresIn: 600))
        await waiting.wait()

        #expect(flow.goBack())
        flow.continueToNextStep()
        #expect(flow.step == .account)
        #expect(flow.accountPhase == .introduction)
        flow.startAccountLink()
        let replacement = try #require(flow.accountLinkTask)
        first.continuation.yield(.linked)
        first.continuation.finish()
        await oldTask.value
        #expect(flow.accountLinkTask != nil)
        #expect(flow.accountLinkRequestInFlight)
        #expect(flow.accountPhase != .linked)

        second.continuation.yield(.linked)
        second.continuation.finish()
        await replacement.value
        #expect(flow.accountPhase == .linked)
        #expect(flow.canContinue)
        #expect(flow.accountLinkTask == nil)
        #expect(!flow.accountLinkRequestInFlight)
    }

    @Test("Back then Continue keeps partial download progress and permits a fresh attempt")
    func downloadBackContinue() async throws {
        let model = OnboardingOperationTestFixture.model(installed: false)
        let first = AsyncThrowingStream<ModelDownloadStreamEvent, Error>.makeStream()
        let second = AsyncThrowingStream<ModelDownloadStreamEvent, Error>.makeStream()
        let service = OnboardingOperationTestPreparation(model: model, streams: [first.stream, second.stream])
        let evidence = OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.running(modelID: model.id))
        let flow = OnboardingOperationTestFixture.flow(service: service, evidence: evidence)
        await flow.runAutomaticWorkForCurrentStep()
        let progressApplied = OnboardingOperationTestGate()
        flow.setDraftChangeHandler { draft in
            if draft.preparationProgress == 0.37 { Task { await progressApplied.open() } }
        }
        flow.startPreparation()
        let oldTask = try #require(flow.preparationTask)
        first.continuation.yield(.progress(file: "weights", bytes: 370, total: 1_000))
        await progressApplied.wait()

        #expect(flow.goBack())
        flow.continueToNextStep()
        #expect(flow.step == .preparation)
        #expect(flow.preparationPhase == .downloadFailed)
        #expect(flow.preparationProgress == 0.37)
        #expect(flow.selectedModelID == model.id)
        #expect(flow.downloadCompletedModelID == nil)
        flow.retryPreparation()
        let replacement = try #require(flow.preparationTask)
        first.continuation.finish()
        await oldTask.value
        #expect(flow.preparationTask != nil)

        second.continuation.yield(.done)
        second.continuation.finish()
        await replacement.value
        #expect(flow.preparationPhase == .ready)
        #expect(flow.providerStartCompleted)
        #expect(await service.downloadedModelIDs == [model.id, model.id])
        #expect(await service.startedModelIDs == [model.id])
    }

    @Test("Back during start leaves retry usable and delayed old success cannot finish the replacement")
    func startBackContinue() async throws {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let firstEntered = OnboardingOperationTestGate()
        let firstRelease = OnboardingOperationTestGate()
        let secondEntered = OnboardingOperationTestGate()
        let secondRelease = OnboardingOperationTestGate()
        let service = OnboardingOperationTestPreparation(
            model: model, startEntered: [firstEntered, secondEntered], startRelease: [firstRelease, secondRelease]
        )
        let evidence = OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.running(modelID: model.id))
        let flow = OnboardingOperationTestFixture.flow(service: service, evidence: evidence)
        await flow.runAutomaticWorkForCurrentStep()
        flow.startPreparation()
        let oldTask = try #require(flow.preparationTask)
        await firstEntered.wait()

        #expect(flow.goBack())
        flow.continueToNextStep()
        #expect(flow.step == .preparation)
        #expect(flow.preparationPhase == .startFailed)
        #expect(flow.downloadCompletedModelID == model.id)
        flow.retryPreparation()
        let replacement = try #require(flow.preparationTask)
        await secondEntered.wait()
        await firstRelease.open()
        await oldTask.value
        #expect(flow.preparationTask != nil)
        #expect(flow.preparationPhase == .startingProvider)
        #expect(!flow.providerStartCompleted)

        await secondRelease.open()
        await replacement.value
        #expect(flow.preparationPhase == .ready)
        #expect(flow.providerStartCompleted)
        #expect(await service.downloadedModelIDs.isEmpty)
        #expect(await service.startedModelIDs == [model.id, model.id])
    }

    @Test("A queued preparation task cannot adopt the revision of a replacement setup")
    func cancelledBeforeTaskEntry() async throws {
        let model = OnboardingOperationTestFixture.model(installed: true)
        let service = OnboardingOperationTestPreparation(model: model)
        let flow = OnboardingOperationTestFixture.flow(service: service)
        await flow.runAutomaticWorkForCurrentStep()
        flow.startPreparation()
        let task = try #require(flow.preparationTask)
        // No actor suspension between scheduling the operation and resetting.
        flow.resetForNewSetup()
        let freshDraft = flow.draft
        await task.value
        #expect(await service.startedModelIDs.isEmpty)
        #expect(flow.draft == freshDraft)
    }

    @Test("Cancelling an untouched welcome flow does not create a draft")
    func cancellationDoesNotInventDraft() {
        let service = OnboardingOperationTestPreparation(model: OnboardingOperationTestFixture.model(installed: false))
        let flow = OnboardingOperationTestFixture.flow(step: .readiness, service: service)
        var drafts: [OnboardingDraft] = []
        flow.setDraftChangeHandler { drafts.append($0) }
        flow.cancelPendingOperations()
        #expect(drafts.isEmpty)
    }
}
