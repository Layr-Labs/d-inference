import Foundation

extension OnboardingFlowModel {
    func showEnrollmentInstructions() {
        guard freezesAutomaticProgress else { return }
        enrollmentPhase = .instructions
    }

    func markSystemSettingsOpened() {
        guard freezesAutomaticProgress,
              enrollmentPhase == .instructions || enrollmentPhase == .systemSettingsOpen
        else { return }
        enrollmentPhase = .systemSettingsOpen
    }

    func beginEnrollment() async {
        if freezesAutomaticProgress {
            if enrollmentPhase == .overview {
                showEnrollmentInstructions()
            } else {
                markSystemSettingsOpened()
            }
            return
        }
        guard let enrollmentRunner else {
            enrollmentFailureDetail = "The enrollment service is unavailable."
            enrollmentPhase = .enrollmentFailed
            return
        }

        enrollmentPollTask?.cancel()
        enrollmentPollTask = nil
        enrollmentPollSession = nil
        let revision = operationRevision
        enrollmentFailureDetail = nil
        enrollmentPhase = .requestingProfile
        do {
            let response = try await enrollmentRunner.enroll()
            guard revision == operationRevision, !Task.isCancelled else { return }
            enrollmentProfilePath = response.profilePath
            enrollmentFailureDetail = response.warning
            switch response.status {
            case .alreadyEnrolled:
                enrollmentPhase = .profileDetected
            case .profileOpened:
                enrollmentPhase = .systemSettingsOpen
                startEnrollmentPolling()
            case .profileDownloaded:
                enrollmentPhase = .instructions
            }
        } catch is CancellationError {
            return
        } catch {
            guard revision == operationRevision else { return }
            enrollmentFailureDetail = error.localizedDescription
            enrollmentPhase = .enrollmentFailed
        }
    }

    func confirmProfileInstallation() async {
        if freezesAutomaticProgress {
            guard enrollmentPhase == .systemSettingsOpen || enrollmentPhase == .instructions else { return }
            await detectPreviewProfile()
            return
        }
        enrollmentPollSession = nil
        enrollmentPollTask?.cancel()
        enrollmentPollTask = nil
        let terminal = await checkEnrollmentEvidence(markMissing: true)
        if !terminal { startEnrollmentPolling() }
    }

    func retryProfileDetection() async {
        if freezesAutomaticProgress {
            await detectPreviewProfile()
        } else {
            enrollmentPollSession = nil
            enrollmentPollTask?.cancel()
            enrollmentPollTask = nil
            let terminal = await checkEnrollmentEvidence(markMissing: true)
            if !terminal { startEnrollmentPolling() }
        }
    }

    func reopenSystemSettings() {
        if freezesAutomaticProgress {
            enrollmentPhase = .systemSettingsOpen
        } else {
            Task { await beginEnrollment() }
        }
    }

    func downloadProfileAgain() {
        guard !conflictingManagementPersists else { return }
        if freezesAutomaticProgress {
            enrollmentPhase = .instructions
        } else {
            Task { await beginEnrollment() }
        }
    }

    func startEnrollmentPolling() {
        guard !freezesAutomaticProgress, enrollmentPollTask == nil else { return }
        let revision = operationRevision
        let session = UUID()
        enrollmentPollSession = session
        enrollmentPollTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.enrollmentPollSession == session {
                    self.enrollmentPollSession = nil
                    self.enrollmentPollTask = nil
                }
            }
            while revision == self.operationRevision, !Task.isCancelled {
                let terminal = await self.checkEnrollmentEvidence(markMissing: false)
                if terminal { return }
                guard await self.pause(self.enrollmentPollInterval) else { return }
            }
        }
    }

    @discardableResult
    func checkEnrollmentEvidence(markMissing: Bool) async -> Bool {
        guard let diagnosticsRunner else {
            if markMissing {
                enrollmentFailureDetail = "The system-check service is unavailable."
                enrollmentPhase = .enrollmentFailed
            }
            return false
        }
        let revision = operationRevision
        if markMissing { enrollmentPhase = .detectingProfile }
        do {
            let report = try await diagnosticsRunner.runDoctorJSON()
            guard revision == operationRevision, !Task.isCancelled else { return true }
            switch EnrollmentEvidence.evaluate(
                report: report,
                providerEvidence: providerEvidenceProvider()
            ) {
            case .enrolled:
                enrollmentFailureDetail = nil
                enrollmentPhase = .profileDetected
                return true
            case .conflicting(let detail):
                enrollmentFailureDetail = detail
                conflictingManagementPersists = true
                enrollmentPhase = .conflictingManagement
                return true
            case .missing(let detail):
                enrollmentFailureDetail = detail
                if markMissing { enrollmentPhase = .profileMissing }
                else if enrollmentPhase == .detectingProfile { enrollmentPhase = .systemSettingsOpen }
                return false
            }
        } catch is CancellationError {
            return true
        } catch {
            guard revision == operationRevision else { return true }
            enrollmentFailureDetail = error.localizedDescription
            if markMissing { enrollmentPhase = .enrollmentFailed }
            return false
        }
    }

    func returnToEnrollmentForSettings() {
        enrollmentPhase = .systemSettingsOpen
        step = .enrollment
        if !freezesAutomaticProgress { startEnrollmentPolling() }
    }

    func returnToEnrollmentForDownload() {
        enrollmentPhase = .instructions
        step = .enrollment
    }

    private func detectPreviewProfile() async {
        let revision = operationRevision
        enrollmentPhase = .detectingProfile
        guard await pause(.milliseconds(760)), revision == operationRevision else { return }
        enrollmentPhase = conflictingManagementPersists ? .conflictingManagement : .profileDetected
    }
}
