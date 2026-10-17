import DarkbloomClusterProtocol
import Foundation

/// What a Mac's own measured hardware says about a model before that model
/// was measured on it, for the choice between tensor parallel and a pipeline:
/// the device index each Mac measures when it is detected
/// (`ClusterDeviceIndex`, a quantized matrix-vector product at a decode shape
/// and at a prefill shape over a known number of weight bytes) gives the
/// bytes per second that Mac moves through such products. Decode is
/// bandwidth-bound: the part of a whole-model step that reads weights is at
/// most the bytes a step reads over that rate, and the rest of the measured
/// step is a per-token floor that does not shrink when a rank holds a share.
/// No chip name, no table: the figures are the Mac's own.
///
/// A shard probe or a request the pair served in tensor parallel replaces
/// the prior (`ClusterDecodeSplit`); the prior only keeps the planner from
/// assuming that a share of the model steps as slowly as the whole model.
public enum ClusterHardwarePrior {
    /// Weight bytes one operation of a `qmm_h<H>_b<B>_g<G>_x<N>_v1` index
    /// benchmark reads: an H x H matrix of B-bit words with a bfloat16 scale
    /// and bias per group of G. Nil for any other benchmark name.
    public static func bytesPerOperation(benchmark: String) -> Double? {
        let parts = benchmark.split(separator: "_").map(String.init)
        guard parts.count == 6, parts[0] == "qmm", parts[5] == "v1",
              parts[1].hasPrefix("h"), parts[2].hasPrefix("b"), parts[3].hasPrefix("g"), parts[4].hasPrefix("x"),
              let hidden = Int(parts[1].dropFirst()), let bits = Int(parts[2].dropFirst()),
              let group = Int(parts[3].dropFirst()), Int(parts[4].dropFirst()) != nil,
              (64...65_536).contains(hidden), (2...8).contains(bits), group > 0, hidden % group == 0 else { return nil }
        return Double(hidden * hidden * bits / 8 + hidden * (hidden / group) * 2 * 2)
    }

    /// Bytes per second this Mac's index moved at the decode shape and at
    /// the prefill shape (tokens x operations per second x bytes per operation).
    public static func bytesPerSecond(_ index: ClusterDeviceIndex) -> (decode: Double, prefill: Double)? {
        guard let bytes = bytesPerOperation(benchmark: index.benchmark), (try? index.validate()) != nil else { return nil }
        return (index.decodeIndex * bytes, index.prefillIndex * bytes)
    }

    /// Weight bytes one decode step reads: every layer's and the output
    /// head's (the embedding is a gather of one row).
    public static func decodeBytesPerToken(_ layout: ClusterModelLayout) -> Int {
        layout.layers.reduce(0) { $0 + $1.weights.loadedBytes } + layout.egress.loadedBytes
    }

    /// Seconds this Mac needs to read a decode step's weights at the rate its
    /// index measured; nil without a usable index. `ClusterDecodeSplit` takes
    /// the smaller of this and the measured whole step as the part a share
    /// divides.
    public static func weightSeconds(profile: ClusterDeviceProfile, layout: ClusterModelLayout) -> Double? {
        guard let index = profile.speedIndex, let rates = bytesPerSecond(index), rates.decode > 0 else { return nil }
        let seconds = Double(decodeBytesPerToken(layout)) / rates.decode
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Absolute whole-model rates from this Mac's index alone: the model is
    /// `decodeBytesPerToken / bytesPerOperation` index operations per token at
    /// either shape. An estimate (the index's operations are smaller than a
    /// model's, so its decode figure is a lower bound); nil without an index.
    public static func absoluteRates(profile: ClusterDeviceProfile, layout: ClusterModelLayout) -> ClusterSpeedRates? {
        guard let index = profile.speedIndex, let rates = bytesPerSecond(index) else { return nil }
        let bytes = Double(decodeBytesPerToken(layout))
        guard bytes > 0 else { return nil }
        let prefill = rates.prefill / bytes, decode = rates.decode / bytes
        guard prefill.isFinite, decode.isFinite, prefill > 0, decode > 0 else { return nil }
        return .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode)
    }

    /// The devices with every speed that is only a ratio (`absolute == false`,
    /// nothing of this model measured on any of them) replaced by its own
    /// index's absolute estimate, when the choice between tensor parallel and
    /// a pipeline is open (the layout has tensor-parallel facts and the link's
    /// reduction was measured keyed): seconds of compute are then compared
    /// with seconds of link. Unchanged otherwise, or when a device that needs
    /// it has no usable index.
    public static func absolute(_ devices: [ClusterPlacementDevice], layout: ClusterModelLayout,
                                link: ClusterLinkCosts) -> [ClusterPlacementDevice] {
        guard layout.tensorParallel != nil, link.reduction?.keyed == true,
              devices.contains(where: { !$0.speed.absolute }) else { return devices }
        var result: [ClusterPlacementDevice] = []
        for device in devices {
            if device.speed.absolute { result.append(device); continue }
            guard let rates = absoluteRates(profile: device.profile, layout: layout),
                  let index = device.profile.speedIndex else { return devices }
            result.append(.init(label: device.label, profile: device.profile,
                speed: .init(source: .transferredByDeviceIndex, absolute: true, rested: rates, sustained: nil,
                    explanation: "estimate from this Mac's own device index (\(index.benchmark)): the model's weight bytes per token "
                        + "at the bytes per second the index moved; this model's own speed is unknown")))
        }
        return result
    }
}
