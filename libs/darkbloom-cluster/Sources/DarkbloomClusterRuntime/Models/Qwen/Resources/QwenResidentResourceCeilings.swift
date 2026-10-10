import Foundation

/// Byte ceilings of one registered model's resident scope. Every registered
/// model has its own row: a larger model never raises another model's ceiling,
/// and the legacy storage constants keep their values and their callers.
/// A ceiling is a refusal bound. It is not a memory grant, a fit on any Mac or
/// a claim about the whole process; the live resource gates stay in force.
struct QwenResidentResourceCeilings: Equatable {
    /// The resident profile's largest request: 8,192 prompt plus 128 output
    /// tokens, prefilled in chunks of at most 512.
    static let maximumContextTokens = 8320
    static let maximumChunkTokens = 512

    /// Largest manifest payload the verified loader will hash for this model.
    let maximumManifestPayloadBytes: Int
    /// Ceiling for the conservative named-state estimate of one request.
    let namedStateByteCeiling: Int
    /// That estimate at the largest request, recomputed from the registered
    /// geometry and required to equal the independently pinned integer.
    let maximumNamedStateBytes: Int

    init(model: QwenRegisteredDenseModel) throws {
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == model }) else {
            throw QwenDenseProfileError("Registered model has no specification")
        }
        try self.init(specification: specification)
    }

    init(specification: QwenDenseRegisteredSpecification) throws {
        let pinnedMaximumNamedStateBytes: Int
        switch specification.model {
        case .qwen35NineB:
            // Unchanged: the 8 GiB manifest bound and the 768 MiB state ceiling
            // the 9B has always been admitted under.
            maximumManifestPayloadBytes = LocalCorrectnessStorage.maximumManifestPayloadBytes
            namedStateByteCeiling = QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling
            pinnedMaximumNamedStateBytes = 754_188_320
        case .qwen38TwentySevenB:
            // The registered manifest total itself (16,320,415,757 bytes) and
            // this model's own estimate at the largest request. Neither is a
            // rounded-up global constant.
            maximumManifestPayloadBytes = specification.manifestBytes
            namedStateByteCeiling = 1_616_248_896
            pinnedMaximumNamedStateBytes = 1_616_248_896
        case .qwen35ThirtyFiveBA3B, .qwen36ThirtyFiveBA3B:
            // As for the 27B: the registered manifest total (20,893,747,852
            // and 21,308,856,601 bytes) and the estimate at the largest
            // request, which the two share with their geometry.
            maximumManifestPayloadBytes = specification.manifestBytes
            namedStateByteCeiling = 563_806_248
            pinnedMaximumNamedStateBytes = 563_806_248
        case .ternaryBonsai2TwentySevenB:
            // As for the 27B: the registered manifest total (8,608,670,713
            // bytes, already above the legacy 8 GiB bound) and this model's
            // own estimate at the largest request. The estimate is the 27B's
            // because the geometry is and the formula counts four bytes per
            // state element, which is exact for this pack's F32 state.
            maximumManifestPayloadBytes = specification.manifestBytes
            namedStateByteCeiling = 1_616_248_896
            pinnedMaximumNamedStateBytes = 1_616_248_896
        }
        maximumNamedStateBytes = try QwenLongPrefillTensorBudget.estimate(
            geometry: specification.expectedGeometry(), maximumTokens: Self.maximumContextTokens,
            chunkSize: Self.maximumChunkTokens).conservativeStateAndBoundaryBytes
        guard specification.manifestBytes > 0, specification.manifestBytes <= maximumManifestPayloadBytes,
              maximumNamedStateBytes == pinnedMaximumNamedStateBytes,
              maximumNamedStateBytes <= namedStateByteCeiling else {
            throw QwenDenseProfileError("Registered resident ceilings differ from the model's own byte vector")
        }
    }
}
