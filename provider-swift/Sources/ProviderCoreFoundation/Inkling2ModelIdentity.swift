import CoreFoundation
import Foundation

/// Identity of Thinking Machines' Inkling 2 Mini, the looped native
/// architecture (`inkling2_loop`), read from `config.json` alone. Pure and
/// MLX-free so discovery, template checks and admission share it.
///
/// The architecture is selected by its exact `model_type` spelling and a
/// configuration whose loop, attention and cache geometry the native model
/// implements; the source organization, file names and quantization label do
/// not establish it. Inkling 2 Small (`inkling2`) is a different architecture.
public enum Inkling2ModelIdentity {
    public static let modelType = "inkling2_loop"
    public static let textModelType = "inkling2_loop_text"
    public static let visionModelType = "inkling2_vision"
    /// The upstream checkpoint this contract was read from.
    public static let upstreamModelID = "thinkingmachines/Inkling-2-Mini"
    public static let upstreamRevision = "6e7c8248f75265bdd4fbab5273304243b5d8c2cb"
    /// Identities that receive the model's serving defaults (paged KV, the
    /// complete prefix cache): its upstream download. A catalog listing id
    /// joins this set when the catalog registers one; any other id of the
    /// architecture keeps the type's own policy only.
    public static let servedModelIDs: Set<String> = [upstreamModelID]
    /// The window this provider serves (prompt plus output), below the
    /// checkpoint's 1,048,576: the largest window measured to serve with the
    /// DSpark drafter on. A 1,048,576-token request allocates far more memory
    /// up front than a 256 GB Mac can spare beside its other models.
    public static let servedContextTokens = 524_288

    public static func isServedModelID(_ modelID: String?) -> Bool {
        modelID.map(servedModelIDs.contains) == true
    }

    /// The served root type, exactly as the checkpoint spells it.
    public static func isNativeType(_ modelType: String?) -> Bool {
        modelType == Self.modelType
    }

    /// `config.json` declares the native looped text tower: the root and text
    /// types, and a cache layout `CacheLayout` can derive.
    public static func declaresNativeTextTower(_ configuration: [String: Any]) -> Bool {
        guard isNativeType(configuration["model_type"] as? String),
            let text = configuration["text_config"] as? [String: Any],
            text["model_type"] as? String == textModelType
        else { return false }
        return CacheLayout(textConfiguration: text) != nil
    }

    /// Images are served with the checkpoint's own vision tower; the model
    /// takes no video or audio (model card: text and image input; the
    /// template refuses any other content part).
    public static func declaresNativeVision(_ configuration: [String: Any]) -> Bool {
        guard declaresNativeTextTower(configuration),
            configuration["language_model_only"] as? Bool != true,
            let vision = configuration["vision_config"] as? [String: Any],
            vision["model_type"] as? String == visionModelType,
            let text = configuration["text_config"] as? [String: Any],
            let width = integer(vision["text_hidden_size"]), width == integer(text["hidden_size"])
        else { return false }
        return true
    }

    /// The per-sequence cache of the looped tower, slot by slot as the native
    /// model visits its layers: every stored layer once, then the loop's core
    /// layers again for each further pass (`loop_config.num_passes`). A full
    /// attention layer keeps every token's K/V; a sliding layer keeps its
    /// window; every slot also carries short-convolution states (K, V, after
    /// attention, after the MLP; `sconv_kernel_size - 1` rows each, FP32).
    public struct CacheLayout: Equatable, Sendable {
        public enum SlotKind: Equatable, Sendable {
            case full
            case sliding(window: Int)
        }

        /// The stored layer each slot applies, in visit order.
        public let slotLayers: [Int]
        public let slots: [SlotKind]
        public let kvHeads: Int
        public let headDim: Int
        public let hiddenSize: Int
        public let convolutionRows: Int
        public let maximumContext: Int?

        public init?(textConfiguration text: [String: Any]) {
            guard let layers = Self.positive(text["num_hidden_layers"]),
                let kvHeads = Self.positive(text["num_key_value_heads"]),
                let headDim = Self.positive(text["head_dim"]),
                let hidden = Self.positive(text["hidden_size"]),
                let kernel = Self.positive(text["sconv_kernel_size"]), kernel >= 2,
                let window = Self.positive(text["sliding_window_size"]),
                let localValues = text["local_layer_ids"] as? [Any],
                let loop = text["loop_config"] as? [String: Any],
                let coreStart = Inkling2ModelIdentity.integer(loop["core_start"]),
                let coreEnd = Inkling2ModelIdentity.integer(loop["core_end"]),
                let passes = Self.positive(loop["num_passes"]),
                layers <= 1024, passes <= 16,
                0 <= coreStart, coreStart < coreEnd, coreEnd <= layers
            else { return nil }
            // A sliding layer with its own head geometry is not this layout.
            if let swaHeads = text["swa_num_key_value_heads"], Inkling2ModelIdentity.integer(swaHeads) != kvHeads { return nil }
            if let swaDim = text["swa_head_dim"], Inkling2ModelIdentity.integer(swaDim) != headDim { return nil }
            var local = Set<Int>()
            for value in localValues {
                guard let id = Inkling2ModelIdentity.integer(value), (0..<layers).contains(id), local.insert(id).inserted
                else { return nil }
            }
            var order = Array(0..<layers)
            for _ in 1..<passes { order += Array(coreStart..<coreEnd) }
            slotLayers = order
            slots = order.map { local.contains($0) ? .sliding(window: window) : .full }
            self.kvHeads = kvHeads
            self.headDim = headDim
            hiddenSize = hidden
            convolutionRows = kernel - 1
            maximumContext = Self.positive(text["model_max_length"])
        }

        public var fullSlotCount: Int { slots.filter { $0 == .full }.count }
        public var slidingSlotCount: Int { slots.count - fullSlotCount }

        /// K and V of one slot for one token, at `bytesPerElement`.
        public func kvBytesPerSlotToken(bytesPerElement: Int = 2) -> Int {
            2 * kvHeads * headDim * bytesPerElement
        }

        /// Marginal K/V bytes per token once every window is full: the full slots'.
        public func kvBytesPerToken(bytesPerElement: Int = 2) -> Int {
            fullSlotCount * kvBytesPerSlotToken(bytesPerElement: bytesPerElement)
        }

        /// The sliding slots' K/V at their windows: the plateau one sequence reaches.
        public func slidingWindowBytes(bytesPerElement: Int = 2) -> Int {
            slots.reduce(0) { total, slot in
                guard case .sliding(let window) = slot else { return total }
                return total + window * kvBytesPerSlotToken(bytesPerElement: bytesPerElement)
            }
        }

        /// The short-convolution states of one sequence: K and V
        /// (`kvHeads × headDim` wide), after attention and after the MLP
        /// (`hiddenSize` wide), `convolutionRows` rows each, in every slot, at
        /// the storage width the native model keeps them in (4 for the
        /// reference's FP32; the SDK model's own state decides at load).
        public func convolutionStateBytes(bytesPerElement: Int = 4) -> Int {
            let width = 2 * kvHeads * headDim + 2 * hiddenSize
            return slots.count * convolutionRows * width * bytesPerElement
        }

        /// The `layer_types` spelling the generic KV estimate reads, one per slot.
        public var layerTypes: [String] {
            slots.map { $0 == .full ? "full_attention" : "sliding_attention" }
        }

        private static func positive(_ value: Any?) -> Int? {
            guard let value = Inkling2ModelIdentity.integer(value), value > 0 else { return nil }
            return value
        }
    }

    /// An integral JSON number, not a Boolean.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
            abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }
}
