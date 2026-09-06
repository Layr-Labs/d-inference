import Foundation

extension SelfUpdater {
    /// Fully downloaded, hash-checked, extracted, and cryptographically
    /// verified update material. It owns only a private side directory; no
    /// live install path or recovery journal has changed yet.
    struct PreparedUpdate: Sendable {
        let stagedBundle: StagedBundle
        let manualOverride: Bool

        var release: ReleaseInfo { stagedBundle.release }

        func discard() {
            stagedBundle.discard()
        }
    }

    enum UpdatePreparationResult: Sendable {
        case terminal(UpdateResult)
        case prepared(PreparedUpdate)
    }

    /// Phase one of an update. Recovery/state is sampled under a short lease,
    /// then the lease is released before any coordinator request, archive
    /// transfer, extraction, signature check, or runtime smoke test.
    func prepareUpdate(
        operation: String,
        manualOverride: Bool
    ) async -> UpdatePreparationResult {
        let recoveryState: UpdateRecoveryState
        do {
            recoveryState = try recoveredStateSnapshot(
                operation: "\(operation)-preflight"
            )
        } catch UpdateError.lockBusy(let reason, _) {
            return .terminal(.busy(reason: reason))
        } catch {
            return .terminal(.replaceFailed(
                reason: "update recovery failed: \(error)"
            ))
        }

        // The preflight session's lexical scope has ended before this await.
        let check = await checkForUpdate(
            manualOverride: manualOverride,
            recoveryState: recoveryState
        )
        switch check {
        case .upToDate(let version):
            return .terminal(.alreadyUpToDate(version: version))
        case .restartRequired(let current, let installed):
            return .terminal(.restartRequired(
                from: current,
                to: installed
            ))
        case .quarantined(let version, let reason):
            return .terminal(.quarantined(
                version: version,
                reason: reason
            ))
        case .checkFailed(let reason):
            return .terminal(.downloadFailed(
                reason: "update check failed: \(reason)"
            ))
        case .updateAvailable(_, let release):
            return await prepareDownloadedUpdate(
                release: release,
                manualOverride: manualOverride
            )
        }
    }

    /// Short, synchronous recovery/state phase shared by foreground and
    /// background update orchestration. Returning from this function proves
    /// the session was released before any caller can begin network I/O.
    func recoveredStateSnapshot(
        operation: String
    ) throws -> UpdateRecoveryState {
        let session = try beginUpdateSession(
            operation: operation,
            timeout: 0
        )
        defer { session.release() }
        try session.recover()
        return try session.readState()
    }

    /// Download and cryptographically stage release metadata already selected
    /// by a caller. Final eligibility is intentionally not assumed: phase two
    /// always evaluates this release again under the mutation lease.
    func prepareDownloadedUpdate(
        release: ReleaseInfo,
        manualOverride: Bool
    ) async -> UpdatePreparationResult {
        if Task.isCancelled {
            return .terminal(.cancelled(
                reason: "update task was cancelled before download"
            ))
        }

        switch await downloadAndVerify(release: release) {
        case .failure(let error):
            if Task.isCancelled {
                return .terminal(.cancelled(
                    reason: "update task was cancelled during download"
                ))
            }
            return .terminal(Self.result(forPreparationError: error))

        case .success(let downloadedFile):
            defer { try? FileManager.default.removeItem(at: downloadedFile) }
            if Task.isCancelled {
                return .terminal(.cancelled(
                    reason: "update task was cancelled after download"
                ))
            }
            switch stageBundle(
                from: downloadedFile,
                release: release
            ) {
            case .failure(let error):
                return .terminal(Self.result(forPreparationError: error))
            case .success(let stagedBundle):
                if Task.isCancelled {
                    stagedBundle.discard()
                    return .terminal(.cancelled(
                        reason: "update task was cancelled after staging"
                    ))
                }
                return .prepared(PreparedUpdate(
                    stagedBundle: stagedBundle,
                    manualOverride: manualOverride
                ))
            }
        }
    }

    /// Phase two of an update. The caller owns `session`; this method recovers
    /// any interrupted transaction, re-reads every release-ordering witness,
    /// and refuses stale staged state before committing the verified tree.
    func finalizePreparedUpdate(
        _ prepared: PreparedUpdate,
        session: UpdateSession,
        beforeInstall: @Sendable () -> Bool = { true }
    ) -> UpdateResult {
        do {
            try session.recover()
            let recoveryState = try session.readState()
            switch evaluateRelease(
                prepared.release,
                recoveryState: recoveryState,
                manualOverride: prepared.manualOverride,
                installRoot: session.store.installRoot
            ) {
            case .upToDate(let version):
                prepared.discard()
                return .alreadyUpToDate(version: version)
            case .restartRequired(let current, let installed):
                prepared.discard()
                return .restartRequired(from: current, to: installed)
            case .quarantined(let version, let reason):
                prepared.discard()
                return .quarantined(version: version, reason: reason)
            case .checkFailed(let reason):
                prepared.discard()
                return .replaceFailed(
                    reason: "staged release revalidation failed: \(reason)"
                )
            case .updateAvailable(let current, _):
                guard !Task.isCancelled, beforeInstall() else {
                    prepared.discard()
                    return .cancelled(
                        reason: Task.isCancelled
                            ? "update task was cancelled before install"
                            : "provider was intentionally stopped before install"
                    )
                }

                switch commitStagedBundle(
                    prepared.stagedBundle,
                    session: session,
                    manualOverride: prepared.manualOverride
                ) {
                case .success:
                    return .updated(
                        from: current,
                        to: prepared.release.version
                    )
                case .failure(let error):
                    // A journal may already own this staging tree. Never erase
                    // replay material; orphan cleanup handles pre-journal
                    // failures after this owner exits.
                    return .replaceFailed(reason: "\(error)")
                }
            }
        } catch {
            prepared.discard()
            return .replaceFailed(
                reason: "update recovery/revalidation failed: \(error)"
            )
        }
    }

    /// Full foreground/startup update wrapper. Only phase two owns the
    /// installation locks.
    func update(
        operation: String,
        manualOverride: Bool,
        beforeInstall: @escaping @Sendable () -> Bool
    ) async -> UpdateResult {
        switch await prepareUpdate(
            operation: operation,
            manualOverride: manualOverride
        ) {
        case .terminal(let result):
            return result
        case .prepared(let prepared):
            let session: UpdateSession
            do {
                session = try beginUpdateSession(
                    operation: "\(operation)-commit",
                    timeout: 0
                )
            } catch UpdateError.lockBusy(let reason, _) {
                prepared.discard()
                return .busy(reason: reason)
            } catch {
                prepared.discard()
                return .replaceFailed(
                    reason: "could not acquire final update lease: \(error)"
                )
            }
            defer { session.release() }
            return finalizePreparedUpdate(
                prepared,
                session: session,
                beforeInstall: beforeInstall
            )
        }
    }

    public func update(manualOverride: Bool = false) async -> UpdateResult {
        await update(
            operation: "update",
            manualOverride: manualOverride,
            beforeInstall: { true }
        )
    }

    private static func result(
        forPreparationError error: UpdateError
    ) -> UpdateResult {
        switch error {
        case .hashMismatch(let expected, let got):
            return .hashMismatch(expected: expected, got: got)
        case .downloadFailed(let reason):
            return .downloadFailed(reason: reason)
        case .invalidURL(let url):
            return .downloadFailed(reason: "invalid download URL: \(url)")
        case .replaceFailed(let reason):
            return .replaceFailed(reason: reason)
        case .lockBusy(let reason, _):
            return .busy(reason: reason)
        }
    }
}
