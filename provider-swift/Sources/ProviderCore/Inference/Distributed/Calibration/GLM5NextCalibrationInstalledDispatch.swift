import Darwin
import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterRemote

/// Public CLI façade only. Internal minting types/transport callbacks never
/// cross into the executable module. Both Macs run their own explicit input.
public enum GLM5NextCalibrationInstalledDispatch {
    struct Input: Codable {
        let version: Int
        let purpose: String
        let sessionID: UUID
        let quotationInput: String
        let peerAddress: String
    }
    public static func run(input: URL, installedExecutable: URL, placementSnapshots: [URL] = []) throws -> Data {
        typealias W = GLM5NextCalibrationDispatchWire
        let bytes = try ClusterConfigurationFiles.read(input, maximum: 16 << 10, privateMode: true)
        let selection = try W.decode(Input.self, bytes)
        guard selection.version == 1, selection.purpose == "finiteCalibration", selection.sessionID != W.zero,
              let address = ClusterLinkIPv4Address(selection.peerAddress), !address.isLoopback,
              !address.isUnspecified else { throw W.invalid("finite installed dispatch selection") }
        try ClusterConfigurationFiles.requireAbsolute(selection.quotationInput)
        let placement = try placementSnapshots.isEmpty ? nil : GLM5NextCalibrationPlacement.select(
            input: URL(fileURLWithPath: selection.quotationInput), snapshots: placementSnapshots)
        // ACTUAL own metadata child has exited zero and its metadata lease has
        // retired before channel admission or finite owner/device lease.
        let completed = try GLM5NextCalibrationInstalledQuote.complete(input: URL(fileURLWithPath: selection.quotationInput),
            installedExecutable: installedExecutable, placement: placement)
        let channel = try GLM5NextCalibrationPairedControl.open(completed: completed,
            sessionID: selection.sessionID, peerAddress: address)
        let paths = try ClusterUserPaths()
        let dispatch = try GLM5NextCalibrationDispatch(completed: completed, channel: channel,
            sessionID: selection.sessionID, fenceDirectory: paths.deviceDirectory.appendingPathComponent("finite-pairs"))
        let oldInt = Darwin.signal(SIGINT, SIG_IGN), oldTerm = Darwin.signal(SIGTERM, SIG_IGN)
        let signals = [DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()),
                       DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())]
        for source in signals { source.setEventHandler { dispatch.cancel() }; source.resume() }
        defer {
            for source in signals { source.cancel() }
            _ = Darwin.signal(SIGINT, oldInt); _ = Darwin.signal(SIGTERM, oldTerm)
        }
        let result = try dispatch.run()
        guard let placement else { return result }
        guard var object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw W.invalid("Invalid finite dispatch result")
        }
        object["automaticPlacement"] = try JSONSerialization.jsonObject(with: ClusterGLMCalibrationPlacement.encode(placement.decision))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
