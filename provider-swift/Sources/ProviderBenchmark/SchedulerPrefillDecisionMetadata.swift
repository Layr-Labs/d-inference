import Foundation
import IOKit.ps
import ProviderCore

struct SchedulerPrefillDecisionRunStart: Sendable {
    let date: Date
    let uptimeNanoseconds: UInt64
    let posture: SchedulerPrefillDecisionReport.PowerThermalPosture
}

public enum SchedulerPrefillDecisionModelID {
    /// Canonical registry label accepted by the signed evidence path.
    ///
    /// A label is either an ASCII alias or `namespace/name`. Filesystem-like
    /// roots, traversal, URI syntax, separators, and invisible ambiguity are
    /// rejected before the model scanner constructs a cache path.
    public static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 192,
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            value.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII
                    && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.controlCharacters.contains(scalar)
            }),
            !value.contains("\\"),
            !value.contains(":"),
            !value.hasPrefix("/"),
            !value.hasPrefix("~")
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(components.count),
            components.allSatisfy({ validComponent($0) })
        else { return false }

        if components.count == 2 {
            let pathRoots: Set<String> = [
                "applications", "home", "private", "tmp", "users", "var", "volumes",
            ]
            guard !pathRoots.contains(components[0].lowercased()) else { return false }
        }
        return true
    }

    private static func validComponent(_ value: Substring) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
            let first = value.utf8.first,
            let last = value.utf8.last,
            isAlphaNumeric(first),
            isAlphaNumeric(last)
        else { return false }
        return value.utf8.allSatisfy {
            isAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
    }
}

enum SchedulerPrefillDecisionMetadata {
    static func inspectModel(
        operatorModelID: String,
        modelDirectory: URL,
        expectedSnapshotAggregateSHA256: String
    ) throws -> SchedulerPrefillDecisionReport.ModelIdentity {
        guard isReportSafeModelID(operatorModelID) else {
            throw SchedulerPrefillDecisionError.invalidModelIdentifier
        }
        let configURL = modelDirectory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let config = try? JSONSerialization.jsonObject(with: configData)
                as? [String: Any]
        else {
            throw SchedulerPrefillDecisionError.invalidModelConfig
        }

        let textConfig = config["text_config"] as? [String: Any]
        let modelType = (config["model_type"] as? String)
            ?? (textConfig?["model_type"] as? String)
        guard modelType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "qwen3_5_moe"
        else {
            throw SchedulerPrefillDecisionError.unexpectedModelType(
                modelType ?? "missing")
        }

        guard let configSHA256 = hashFile(atPath: configURL.path),
            let snapshotAggregateSHA256 = WeightHasher.computeHash(
                snapshotDir: modelDirectory,
                modelID: operatorModelID)
        else {
            throw SchedulerPrefillDecisionError.modelHashUnavailable
        }
        guard snapshotAggregateSHA256
            .caseInsensitiveCompare(expectedSnapshotAggregateSHA256) == .orderedSame
        else {
            throw SchedulerPrefillDecisionError.modelHashMismatch(
                expected: expectedSnapshotAggregateSHA256.lowercased(),
                actual: snapshotAggregateSHA256.lowercased())
        }

        let architectures = (
            (config["architectures"] as? [String])
                ?? (textConfig?["architectures"] as? [String])
                ?? []
        ).sorted()
        return .init(
            operatorModelID: operatorModelID,
            modelType: modelType!.lowercased(),
            architectures: architectures,
            configSHA256: configSHA256.lowercased(),
            snapshotAggregateSHA256: snapshotAggregateSHA256.lowercased())
    }

    static func isReportSafeModelID(_ value: String) -> Bool {
        SchedulerPrefillDecisionModelID.isCanonical(value)
    }

    static func start() -> SchedulerPrefillDecisionRunStart {
        .init(
            date: Date(),
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            posture: capturePosture())
    }

    static func finish(
        _ start: SchedulerPrefillDecisionRunStart,
        sourceSHA: String?,
        signedIdentity: SignedReleaseIdentity.Verified? = nil
    ) throws -> SchedulerPrefillDecisionReport.Reproducibility {
        let hardware = try HardwareDetector.detect()
        let executableSHA256: String
        if let signedIdentity {
            executableSHA256 = signedIdentity.executableSHA256
        } else {
            guard let hash = selfBinaryHash() else {
                throw SchedulerPrefillDecisionError.executableHashUnavailable
            }
            executableSHA256 = hash
        }
        let finished = Date()
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        ) / 1_000_000_000
        return .init(
            startedAtUTC: iso8601(start.date),
            finishedAtUTC: iso8601(finished),
            elapsedSeconds: elapsed,
            sourceSHA: sourceSHA,
            providerVersion: signedIdentity?.providerVersion ?? ProviderCore.version,
            executableName: signedIdentity?.executableName
                ?? Bundle.main.executableURL?.lastPathComponent
                ?? ProcessInfo.processInfo.processName,
            executableSHA256: executableSHA256,
            buildConfiguration: buildConfiguration,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: .init(
                machineModel: hardware.machineModel,
                chipName: hardware.chipName,
                memoryGB: hardware.memoryGb,
                gpuCores: hardware.gpuCores),
            postureAtStart: start.posture,
            postureAtEnd: capturePosture())
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func capturePosture()
        -> SchedulerPrefillDecisionReport.PowerThermalPosture
    {
        let power = powerSnapshot()
        return .init(
            powerSource: power.source,
            batteryPercent: power.batteryPercent,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState))
    }

    private static func powerSnapshot() -> (source: String, batteryPercent: Int?) {
        guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else {
            return ("unknown", nil)
        }
        let info = unmanagedInfo.takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(info)?
            .takeUnretainedValue() as String?
        let source: String
        switch providing {
        case kIOPSACPowerValue:
            source = "ac"
        case kIOPSBatteryPowerValue:
            source = "battery"
        default:
            source = "unknown"
        }

        guard let unmanagedSources = IOPSCopyPowerSourcesList(info) else {
            return (source, nil)
        }
        let sources = unmanagedSources.takeRetainedValue() as [CFTypeRef]
        for item in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(
                info, item),
                let description = unmanagedDescription.takeUnretainedValue()
                    as? [String: Any],
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int,
                maximum > 0
            else { continue }
            return (
                source,
                min(100, max(0, Int(
                    (Double(current) / Double(maximum) * 100).rounded()))))
        }
        return (source, nil)
    }

    private static func thermalStateName(
        _ state: ProcessInfo.ThermalState
    ) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
