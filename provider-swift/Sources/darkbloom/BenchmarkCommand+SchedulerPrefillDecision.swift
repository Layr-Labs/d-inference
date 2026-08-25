import ArgumentParser
import Foundation
import ProviderBenchmark
import ProviderCore

extension Benchmark {
    struct SignedSchedulerPrefillDecisionOptions: Equatable {
        let modelID: String
        let expectedModelAggregateSHA256: String
        let expectedRegisteredBinarySHA256: String
        let expectedVersion: String
        let sourceSHA: String
        let iterations: Int
        let kvBackend: EngineV2KVBackendSelection
        let output: String?
    }

    enum SignedSchedulerPrefillDecisionInputError: Error, CustomStringConvertible {
        case missing(String)
        case invalidModelID
        case invalidSHA256(String)
        case invalidSourceSHA
        case invalidVersion
        case invalidIterations
        case invalidKVBackend

        var description: String {
            switch self {
            case .missing(let option):
                "\(option) is required with --scheduler-prefill-decision"
            case .invalidModelID:
                "--model must be a canonical registry label, never a local path"
            case .invalidSHA256(let option):
                "\(option) must be 64 lowercase hexadecimal characters"
            case .invalidSourceSHA:
                "--source-sha must be 40 or 64 lowercase hexadecimal characters"
            case .invalidVersion:
                "--expected-version must be non-empty and contain no whitespace or controls"
            case .invalidIterations:
                "--decision-iterations must be at least "
                    + "\(SchedulerPrefillDecisionReport.minimumLiveIterations)"
            case .invalidKVBackend:
                "--kv-backend must be one of: auto, contiguous, paged"
            }
        }
    }

    func signedSchedulerPrefillDecisionOptions()
        throws -> SignedSchedulerPrefillDecisionOptions
    {
        guard let model else {
            throw SignedSchedulerPrefillDecisionInputError.missing("--model")
        }
        guard SchedulerPrefillDecisionModelID.isCanonical(model) else {
            throw SignedSchedulerPrefillDecisionInputError.invalidModelID
        }
        let expectedModelHash = try requiredOption(
            expectedModelAggregateSHA256,
            name: "--expected-model-aggregate-sha256")
        guard Self.isLowercaseHex(expectedModelHash, lengths: [64]) else {
            throw SignedSchedulerPrefillDecisionInputError.invalidSHA256(
                "--expected-model-aggregate-sha256")
        }
        let expectedBinaryHash = try requiredOption(
            expectedRegisteredBinarySHA256,
            name: "--expected-registered-binary-sha256")
        guard Self.isLowercaseHex(expectedBinaryHash, lengths: [64]) else {
            throw SignedSchedulerPrefillDecisionInputError.invalidSHA256(
                "--expected-registered-binary-sha256")
        }
        let expectedVersionValue = try requiredOption(
            self.expectedVersion,
            name: "--expected-version")
        guard expectedVersionValue == expectedVersionValue.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !expectedVersionValue.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw SignedSchedulerPrefillDecisionInputError.invalidVersion
        }
        let sourceSHAValue = try requiredOption(self.sourceSHA, name: "--source-sha")
        guard Self.isLowercaseHex(sourceSHAValue, lengths: [40, 64]) else {
            throw SignedSchedulerPrefillDecisionInputError.invalidSourceSHA
        }
        guard decisionIterations >= SchedulerPrefillDecisionReport.minimumLiveIterations else {
            throw SignedSchedulerPrefillDecisionInputError.invalidIterations
        }
        guard let backend = EngineV2KVBackendSelection(
            rawValue: kvBackend.lowercased()),
            kvBackend == kvBackend.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw SignedSchedulerPrefillDecisionInputError.invalidKVBackend
        }
        return .init(
            modelID: model,
            expectedModelAggregateSHA256: expectedModelHash,
            expectedRegisteredBinarySHA256: expectedBinaryHash,
            expectedVersion: expectedVersionValue,
            sourceSHA: sourceSHAValue,
            iterations: decisionIterations,
            kvBackend: backend,
            output: output)
    }

    func runSignedSchedulerPrefillDecision() async throws {
        let options: SignedSchedulerPrefillDecisionOptions
        do {
            options = try signedSchedulerPrefillDecisionOptions()
        } catch {
            printError(String(describing: error))
            throw ExitCode(2)
        }

        let signedIdentity: SignedReleaseIdentity.Verified
        do {
            signedIdentity = try SignedReleaseIdentity.verifyCurrent(
                expectedBinarySHA256: options.expectedRegisteredBinarySHA256,
                expectedVersion: options.expectedVersion)
        } catch {
            printError(String(describing: error))
            throw ExitCode(2)
        }

        guard let modelDirectory = ModelScanner.resolveLocalPath(
            modelID: options.modelID)
        else {
            printError("registered model '\(options.modelID)' is not available locally")
            throw ExitCode(2)
        }

        let report: SchedulerPrefillDecisionReport
        do {
            report = try await SchedulerPrefillBenchmark.signedQwenPolicyEvaluation(
                modelID: options.modelID,
                modelDirectory: modelDirectory,
                expectedSnapshotAggregateSHA256:
                    options.expectedModelAggregateSHA256,
                sourceSHA: options.sourceSHA,
                iterations: options.iterations,
                kvBackend: options.kvBackend,
                signedIdentity: signedIdentity)
        } catch {
            printError("signed scheduler-prefill evidence is invalid: \(error)")
            throw ExitCode(2)
        }

        do {
            let data = try JSONEncoder.schedulerPrefillDecision.encode(report)
            if let output = options.output, output != "-" {
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } catch {
            printError("could not emit signed scheduler-prefill JSON: \(error)")
            throw ExitCode(2)
        }

        let status = SchedulerPrefillDecisionExitStatus.value(for: report)
        guard status == 0 else { throw ExitCode(status) }
    }

    private func requiredOption(_ value: String?, name: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw SignedSchedulerPrefillDecisionInputError.missing(name)
        }
        return value
    }

    private static func isLowercaseHex(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.count) && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

private extension JSONEncoder {
    static var schedulerPrefillDecision: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
