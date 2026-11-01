import DarkbloomClusterProtocol
import Foundation

/// How fast a decoding Mac is predicted to decode with the model's own
/// speculative (MTP) head, and whether the planner prefers the head there.
/// The rule, in order:
///
/// 1. A rate this device measured with the head (a speed record's
///    `speculativeDecodeTokensPerSecond`) is used as it is, in either
///    direction: the head is preferred when it is faster than plain decode.
/// 2. Otherwise, on a GPU of the first generation with matrix accelerators
///    in every core or a later one (Apple M5 and after, the chips the head
///    was measured paying on), the head is preferred, as one Mac runs it by
///    default, and the model's resident row factor (`ClusterModelLayout.
///    speculativeDecodeFactor`, the smallest pair speed-up measured), when
///    the row has one, scales the plain rate.
/// 3. Anywhere else plain decode is preferred: plain greedy decode is the
///    reference itself, and on the M3 Ultra the product's own head decoded
///    slower than plain decode (98.5 against 104.8 tok/s at 1,024 tokens,
///    77.9 against 100.8 at 8,192). The plain phase split ranks before the
///    same split with the head there.
///
/// The generation is read from the chip name the Mac reports, by its form
/// ("Apple M<generation> ..."), not from a table of machines; a name of
/// another form decides nothing, so plain decode is preferred there.
public enum ClusterSpeculativeCredit {
    /// Apple M5 is the first generation whose GPU cores carry the matrix
    /// (neural) accelerators the speculative verify window runs on.
    public static let firstAcceleratedGeneration = 5

    public enum Basis: String, Codable, Sendable {
        /// This device's own measured rate with the head.
        case measured
        /// The model row's factor on an accelerated GPU.
        case rowFactor
    }

    /// The Apple silicon generation in a chip name such as "Apple M5 Max";
    /// nil for a name of another form.
    public static func generation(chip: String) -> Int? {
        let words = chip.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].hasPrefix("M") else { return nil }
        let digits = words[1].dropFirst()
        guard !digits.isEmpty, digits.count <= 3, digits.allSatisfy(\.isASCII), let value = Int(digits) else { return nil }
        return value
    }

    /// True for a GPU of the first accelerated generation or a later one:
    /// without a measurement of its own, such a device prefers the head and
    /// is credited the row's factor.
    public static func acceleratedGPU(_ profile: ClusterDeviceProfile) -> Bool {
        (generation(chip: profile.chip) ?? 0) >= firstAcceleratedGeneration
    }

    /// The decode rate `device` reaches with the model's head under these
    /// plain `rates`, and on what basis; nil when nothing credits the head
    /// there (then it decodes at the plain rate at best).
    public static func rate(_ rates: ClusterSpeedRates, device: ClusterPlacementDevice,
                            layout: ClusterModelLayout) -> (tokensPerSecond: Double, basis: Basis)? {
        guard layout.generationModes.contains(.phaseSplitMTP) else { return nil }
        if let measured = rates.speculativeDecodeTokensPerSecond { return (measured, .measured) }
        guard let factor = layout.speculativeDecodeFactor, acceleratedGPU(device.profile) else { return nil }
        return (rates.decodeTokensPerSecond * factor, .rowFactor)
    }

    /// The decode speed-up a pipeline's speculative rounds
    /// (`pipeline_mtp_v1`) are credited with when `rates` are the decoding
    /// rank's: measured only, the served rounds over what the same placement
    /// served plainly, as served calibration recorded it for this device
    /// (`ClusterSpeedRates.pipelineSpeculativeFactor`). Never the device's own
    /// rate with the head (a single-Mac or phase-split figure): every rank
    /// verifies a pipeline's window, so no such rate, chip generation or row
    /// factor predicts it. Nil without a measurement, and the plain pipeline
    /// then ranks first.
    ///
    /// `recorded`: the speed-up the model's passing qualification records of
    /// the rounds measured on the pair that qualified them
    /// (`ClusterPlacementPolicy.recordedPipelineSpeculativeFactor`), used only
    /// while this device has no served measurement: a lossless mode measured
    /// faster is on by default (owner rule), and the user's own served
    /// records replace the bench's figure as soon as they exist.
    public static func pipelineFactor(_ rates: ClusterSpeedRates, recorded: Double? = nil) -> Double? {
        if let factor = rates.pipelineSpeculativeFactor, factor.isFinite, factor > 0 { return factor }
        guard let recorded, recorded.isFinite, recorded > 0 else { return nil }
        return recorded
    }

    /// True when this device should decode with the head rather than
    /// without it: by its own measurement when it has one, else by its GPU's
    /// generation.
    public static func prefersHead(_ rates: ClusterSpeedRates, device: ClusterPlacementDevice, layout: ClusterModelLayout) -> Bool {
        guard layout.generationModes.contains(.phaseSplitMTP) else { return false }
        if let measured = rates.speculativeDecodeTokensPerSecond { return measured > rates.decodeTokensPerSecond }
        return acceleratedGPU(device.profile)
    }
}
