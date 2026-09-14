import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime

extension SandboxHostProductionAdapter {
    func admitExecute(
        _ payload: SandboxWireCommand
    ) -> SandboxHostControlAdmission {
        guard isolationReadiness.permitsJobs else {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: AdapterError.isolationUnavailable.code
                    )
                )
            )
        }
        guard let idempotencyKey = UUID(uuidString: payload.idempotencyKey),
              let executable = payload.arguments.first
        else {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: AdapterError.invalidRequest.code
                    )
                )
            )
        }
        if let active = activeCommands[payload.commandID] {
            guard active.scope == payload.scope else {
                return SandboxHostControlAdmission(
                    response: .command(
                        Self.failedCommand(
                            payload,
                            errorCode: AdapterError.staleAuthority.code
                        )
                    )
                )
            }
            return SandboxHostControlAdmission {
                await self.commandResponse(
                    payload,
                    executionID: active.executionID,
                    task: active.task
                )
            }
        }

        let request: SandboxGuestCommandRequest
        do {
            request = try SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: executable,
                arguments: Array(payload.arguments.dropFirst()),
                environment: payload.environment ?? [:],
                workingDirectory: payload.workingDirectory ?? "/workspace",
                timeoutSeconds: payload.timeoutSeconds
            )
        } catch {
            return SandboxHostControlAdmission(
                response: .command(
                    Self.failedCommand(
                        payload,
                        errorCode: Self.errorCode(error)
                    )
                )
            )
        }

        let runtime = runtime
        let scope = payload.scope.operationScope
        let name = Self.virtualMachineName(for: payload.scope)
        let task = Task {
            try await runtime.execute(
                scope: scope,
                name: name,
                request: request
            )
        }
        let executionID = UUID()
        activeCommands[payload.commandID] = ActiveCommand(
            executionID: executionID,
            scope: payload.scope,
            task: task
        )
        return SandboxHostControlAdmission {
            await self.commandResponse(
                payload,
                executionID: executionID,
                task: task
            )
        }
    }

    private func commandResponse(
        _ payload: SandboxWireCommand,
        executionID: UUID,
        task: Task<SandboxGuestCommandResult, Error>
    ) async -> SandboxHostControlResponse {
        defer {
            if activeCommands[payload.commandID]?.executionID == executionID {
                activeCommands.removeValue(forKey: payload.commandID)
            }
        }
        do {
            let result = try await task.value
            let state: SandboxWireCommandState
            if result.timedOut {
                state = .timedOut
            } else if result.exitCode == 0 {
                state = .succeeded
            } else {
                state = .failed
            }
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: state,
                    exitCode: result.exitCode,
                    standardOutput: String(
                        decoding: result.standardOutput,
                        as: UTF8.self
                    ),
                    standardError: String(
                        decoding: result.standardError,
                        as: UTF8.self
                    ),
                    outputTruncated: result.standardOutputTruncated
                        || result.standardErrorTruncated,
                    errorCode: result.timedOut ? "command_timeout" : nil
                )
            )
        } catch is CancellationError {
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: .cancelled
                )
            )
        } catch {
            let code = Self.errorCode(error)
            let state: SandboxWireCommandState =
                code == "operation_timeout" ? .timedOut : .failed
            return .command(
                SandboxWireCommandStatus(
                    commandID: payload.commandID,
                    scope: payload.scope,
                    state: state,
                    exitCode: state == .failed ? -1 : nil,
                    errorCode: code
                )
            )
        }
    }

    func admitCancellation(
        _ payload: SandboxWireCommandControl
    ) -> SandboxHostControlAdmission {
        guard let active = activeCommands[payload.commandID] else {
            let runtime = runtime
            let scope = payload.scope.operationScope
            let name = Self.virtualMachineName(for: payload.scope)
            let stopProof: Task<Void, Error> = Task {
                try await runtime.stop(scope: scope, name: name)
            }
            return SandboxHostControlAdmission {
                await self.cancellationResponse(
                    payload,
                    active: nil,
                    stopProof: stopProof
                )
            }
        }
        guard active.scope == payload.scope else {
            return SandboxHostControlAdmission(
                response: .command(
                    SandboxWireCommandStatus(
                        commandID: payload.commandID,
                        scope: payload.scope,
                        state: .failed,
                        exitCode: -1,
                        errorCode: AdapterError.staleAuthority.code
                    )
                )
            )
        }
        active.task.cancel()
        return SandboxHostControlAdmission {
            await self.cancellationResponse(
                payload,
                active: active,
                stopProof: nil
            )
        }
    }

    private func cancellationResponse(
        _ payload: SandboxWireCommandControl,
        active: ActiveCommand?,
        stopProof: Task<Void, Error>?
    ) async -> SandboxHostControlResponse {
        if let active {
            defer {
                if activeCommands[payload.commandID]?.executionID
                    == active.executionID
                {
                    activeCommands.removeValue(forKey: payload.commandID)
                }
            }
            do {
                _ = try await active.task.value
            } catch is CancellationError {
                // Lume returns cancellation only after guest cleanup and its
                // fenced VM stop have completed.
            } catch {
                return Self.failedCancellation(payload, error: error)
            }
        } else {
            do {
                guard let stopProof else {
                    return Self.failedCancellation(
                        payload,
                        error: AdapterError.cancellationProofUnavailable
                    )
                }
                try await stopProof.value
            } catch {
                return Self.failedCancellation(payload, error: error)
            }
        }
        return .command(
            SandboxWireCommandStatus(
                commandID: payload.commandID,
                scope: payload.scope,
                state: .cancelled
            )
        )
    }
}
