import Darwin
import Foundation
import Security
@preconcurrency import DeviceCheck

/// Local qualification evidence, never a serving claim or signed transcript.
/// Capturing does not initialize AppKit, register an app, or generate Apple keys.
public struct AppAttestWorkerRuntimeDiagnostics: Codable, Sendable, Equatable {
    public enum EntitlementValue: Codable, Sendable, Equatable {
        case absent, invalid
        case string(String)
        case strings([String])
        case boolean(Bool)
    }

    public let processID: Int32
    public let parentProcessID: Int32
    public let mainThread: Bool
    public let launchSession: AppAttestLaunchSession
    public let osVersion: String
    public let osBuild: String?
    public let hardwareModel: String?
    public let bundleURL: String
    public let bundleIdentifier: String?
    public let bundlePackageType: String?
    public let appKitClassLoaded: Bool
    public let isSupportedBeforeInspection: Bool
    public let isSupportedAfterInspection: Bool
    public let signatureQueryStatus: Int32
    public let signatureFlags: UInt32?
    public let dynamicCodeStatusBeforeInspection: UInt32?
    public let dynamicCodeStatusAfterInspection: UInt32?
    public let rawSigningIdentifier: String?
    public let rawEntitlements: [String: EntitlementValue]?
    public let secTaskAvailable: Bool
    public let effectiveEntitlements: [String: EntitlementValue]?
    public let effectiveEntitlementsErrorCode: Int?
    public let effectiveSigningIdentifier: String?
    public let effectiveSigningIdentifierErrorCode: Int?

    /// Call only while no Apple operation is outstanding. The two real support
    /// reads expose any lazy initialization caused by inspecting effective grants.
    public static func capture() -> Self {
        let supportedBefore = DCAppAttestService.shared.isSupported
        let before = signingInformation()
        let task = SecTaskCreateFromSelf(nil)
        var valuesError: Unmanaged<CFError>?
        var identifierError: Unmanaged<CFError>?
        let effective = task.flatMap {
            SecTaskCopyValuesForEntitlements($0, entitlementNames as CFArray, &valuesError) as? [String: Any]
        }
        let identifier = task.flatMap { SecTaskCopySigningIdentifier($0, &identifierError) as String? }
        let supportedAfter = DCAppAttestService.shared.isSupported
        let after = signingInformation()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            processID: getpid(), parentProcessID: getppid(), mainThread: Thread.isMainThread,
            launchSession: AppAttestRuntimeContext.current().launchSession,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            osBuild: systemString("kern.osversion"), hardwareModel: systemString("hw.model"),
            bundleURL: Bundle.main.bundleURL.resolvingSymlinksInPath().absoluteString,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePackageType: Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
            appKitClassLoaded: NSClassFromString("NSApplication") != nil,
            isSupportedBeforeInspection: supportedBefore, isSupportedAfterInspection: supportedAfter,
            signatureQueryStatus: before.status,
            signatureFlags: (before.values?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
            dynamicCodeStatusBeforeInspection: (before.values?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value,
            dynamicCodeStatusAfterInspection: (after.values?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value,
            rawSigningIdentifier: before.values?[kSecCodeInfoIdentifier as String] as? String,
            rawEntitlements: before.values.map { knownEntitlements($0[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]) },
            secTaskAvailable: task != nil, effectiveEntitlements: effective.map(knownEntitlements),
            effectiveEntitlementsErrorCode: valuesError.map { CFErrorGetCode($0.takeRetainedValue()) },
            effectiveSigningIdentifier: identifier,
            effectiveSigningIdentifierErrorCode: identifierError.map { CFErrorGetCode($0.takeRetainedValue()) })
    }

    static let entitlementNames = [
        AppAttestEntitlementPolicy.optIn, AppAttestEntitlementPolicy.environment,
        "application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier",
        "keychain-access-groups", "com.apple.security.app-sandbox", "com.apple.security.get-task-allow",
        "get-task-allow", "com.apple.security.cs.disable-library-validation",
    ]

    static func knownEntitlements(_ values: [String: Any]) -> [String: EntitlementValue] {
        Dictionary(uniqueKeysWithValues: entitlementNames.map { key in
            let value: EntitlementValue
            if let raw = values[key] {
                if let string = raw as? String, string.utf8.count <= 256 {
                    value = .string(string)
                } else if let strings = raw as? [String], strings.count <= 8,
                          strings.allSatisfy({ $0.utf8.count <= 256 }) {
                    value = .strings(strings)
                } else if let boolean = raw as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() {
                    value = .boolean(boolean.boolValue)
                } else {
                    value = .invalid
                }
            } else {
                value = .absent
            }
            return (key, value)
        })
    }

    private static func signingInformation() -> (status: OSStatus, values: [String: Any]?) {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf([], &code)
        guard copyStatus == errSecSuccess, let code else { return (copyStatus, nil) }
        var values: CFDictionary?
        // SecCode.h explicitly accepts a running SecCodeRef here, despite the
        // C parameter's SecStaticCodeRef spelling. Preserve that CF object rather
        // than calling SecCodeCopyStaticCode, which discards dynamic status.
        let dynamicCode = unsafeBitCast(code, to: SecStaticCode.self)
        let status = SecCodeCopySigningInformation(dynamicCode,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation), &values)
        return (status, values as? [String: Any])
    }

    private static func systemString(_ name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        var size = buffer.count
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0, size > 0, size <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(size).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
