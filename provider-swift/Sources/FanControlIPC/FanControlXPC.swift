import Foundation

public enum FanControlIPC {
    public static let protocolVersion = 1
    public static let replyTimeoutSeconds: TimeInterval = 30
    public static let machServiceName = "io.darkbloom.provider.fan-helper"
    public static let clientBundleIdentifier = "io.darkbloom.provider"
    public static let helperBundleIdentifier = "io.darkbloom.provider.fan-helper"
    public static let teamIdentifier = "SLDQ2GJ6TL"

    public static let clientRequirement =
        signingRequirement(identifier: clientBundleIdentifier)
    public static let helperRequirement =
        signingRequirement(identifier: helperBundleIdentifier)

    private static func signingRequirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

@objc public protocol FanControlXPCProtocol {
    func getProtocolVersion(
        withReply reply: @escaping (Int) -> Void
    )

    func acquireLease(
        speedPercent: Double,
        triggerTemperatureCelsius: Double,
        withReply reply: @escaping (NSString?, NSString?) -> Void
    )

    func renewLease(
        _ leaseID: NSString,
        sequence: UInt64,
        inferenceActive: Bool,
        withReply reply: @escaping (
            Bool,
            Double,
            NSString?,
            NSString?
        ) -> Void
    )

    func releaseLease(
        _ leaseID: NSString,
        withReply reply: @escaping (NSString?) -> Void
    )

    func restoreAutomatic(
        withReply reply: @escaping (NSString?) -> Void
    )
}
