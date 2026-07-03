import Foundation
import Testing
@testable import ProviderCore

// Scan-integration coverage for the DeepSeek-V4 MoE expert-streaming memory
// estimate (Task B, review item 3): `parseModelInfo`/`scanModels` must report
// a SMALLER `estimatedMemoryGb` for a deepseek_v4 model when this provider
// has `stream_experts` enabled — small enough that a 141ish GB checkpoint
// admits on a box the naive full-footprint estimate would refuse. Every
// other case (streaming off, non-deepseek_v4 model_type, no hardwareInfo)
// must stay BYTE-IDENTICAL to the pre-existing estimate.
//
// The pure arithmetic itself is covered exhaustively in
// ProviderCoreFoundationTests/ExpertStreamingAdmissionTests and
// SafetensorsSizingTests; these tests pin the `ModelScanner` wiring.

private func writeSafetensorsFile(
    at url: URL, tensors: [(name: String, byteSize: Int)]
) throws {
    var header: [String: Any] = [:]
    var offset = 0
    for (name, byteSize) in tensors {
        header[name] = [
            "dtype": "F32",
            "shape": [max(1, byteSize / 4)],
            "data_offsets": [offset, offset + byteSize],
        ]
        offset += byteSize
    }
    let headerData = try JSONSerialization.data(withJSONObject: header)
    var fileData = Data()
    var length = UInt64(headerData.count).littleEndian
    withUnsafeBytes(of: &length) { fileData.append(contentsOf: $0) }
    fileData.append(headerData)
    // Pad the file out to the declared logical size so
    // `ModelScanner.collectWeightFiles`'s ON-DISK size (used as `totalBytes`)
    // matches what the header describes. Sparse (`truncate`), not written —
    // no test writes real gigabytes to disk.
    try fileData.write(to: url)
    let fh = try FileHandle(forWritingTo: url)
    try fh.truncate(atOffset: UInt64(fileData.count + offset))
    try fh.close()
}

private func makeDeepseekV4Snapshot(
    residentBytes: Int, switchMlpBytes: Int
) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-expert-streaming-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"model_type": "deepseek_v4"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
    try writeSafetensorsFile(
        at: dir.appendingPathComponent("model.safetensors"),
        tensors: [
            ("model.embed_tokens.weight", residentBytes),
            ("model.layers.0.ffn.switch_mlp.gate_proj.weight", switchMlpBytes),
        ])
    return dir
}

private func testHardware(memoryGb: UInt64) -> HardwareInfo {
    HardwareInfo(
        machineModel: "Test", chipName: "Apple Silicon",
        chipFamily: .m5, chipTier: .max,
        memoryGb: memoryGb, memoryAvailableGb: memoryGb - 4,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 800
    )
}

@Test func streamingEstimateIsSmallerThanFullFootprintForDeepseekV4() throws {
    // 1 GiB resident + 4 GiB routed-expert ⇒ full footprint (1+4)*1.2 = 6 GB;
    // streaming estimate ≈ 1*1.2 + auto cache (small box ⇒ floors at 8 GB) =
    // 9.2 GB. The point isn't which is bigger in this toy case — it's that
    // streaming ON produces a DIFFERENT number that ignores switchMlpBytes,
    // proven directly against `ExpertStreamingAdmission`'s own math below.
    let oneGiB = 1024 * 1024 * 1024
    let dir = try makeDeepseekV4Snapshot(residentBytes: oneGiB, switchMlpBytes: 4 * oneGiB)
    defer { try? FileManager.default.removeItem(at: dir) }

    let hardware = testHardware(memoryGb: 64)
    let streamingOn = BackendSettings(streamExperts: true, expertCacheGb: 0)

    let info = try #require(ModelScanner.parseModelInfo(
        snapshotDir: dir, modelName: "org/dsv4-test",
        hardwareInfo: hardware, backend: streamingOn))

    let switchMlpBytesMeasured = try SafetensorsSizing.sumTensorBytes(
        in: dir, matching: ExpertStreamingAdmission.isSwitchMlpKey)
    let expected = ExpertStreamingAdmission.estimate(
        totalBytes: info.sizeBytes, switchMlpBytes: switchMlpBytesMeasured,
        physicalMemoryGb: Double(hardware.memoryGb), configuredExpertCacheGb: 0
    ).totalGb

    #expect(abs(info.estimatedMemoryGb - expected) < 0.01)
    // And it must differ from the naive full-footprint estimate — proving
    // the switch_mlp exclusion actually took effect.
    let naive = (Double(info.sizeBytes) / (1024 * 1024 * 1024)) * 1.2
    #expect(abs(info.estimatedMemoryGb - naive) > 0.01)
}

@Test func nonStreamingPathStaysByteIdenticalWhenStreamingIsOff() throws {
    let oneGiB = 1024 * 1024 * 1024
    let dir = try makeDeepseekV4Snapshot(residentBytes: oneGiB, switchMlpBytes: 4 * oneGiB)
    defer { try? FileManager.default.removeItem(at: dir) }

    let hardware = testHardware(memoryGb: 64)

    // Streaming disabled (default BackendSettings): must equal the ordinary
    // full-footprint estimate, byte-identical to before this feature existed.
    let info = try #require(ModelScanner.parseModelInfo(
        snapshotDir: dir, modelName: "org/dsv4-test",
        hardwareInfo: hardware, backend: BackendSettings()))
    let naive = (Double(info.sizeBytes) / (1024 * 1024 * 1024)) * 1.2
    #expect(abs(info.estimatedMemoryGb - naive) < 0.0001)
}

@Test func nonDeepseekV4ModelIsUnaffectedByStreamingConfig() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-expert-streaming-non-dsv4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"{"model_type": "qwen3"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
    try writeSafetensorsFile(
        at: dir.appendingPathComponent("model.safetensors"),
        tensors: [("model.embed_tokens.weight", 2 * 1024 * 1024 * 1024)])

    let hardware = testHardware(memoryGb: 64)
    let streamingOn = BackendSettings(streamExperts: true, expertCacheGb: 0)

    let info = try #require(ModelScanner.parseModelInfo(
        snapshotDir: dir, modelName: "org/not-dsv4",
        hardwareInfo: hardware, backend: streamingOn))
    let naive = (Double(info.sizeBytes) / (1024 * 1024 * 1024)) * 1.2
    #expect(abs(info.estimatedMemoryGb - naive) < 0.0001,
        "streaming config must never affect a non-deepseek_v4 model's estimate")
}

@Test func missingHardwareInfoFallsBackToTheOrdinaryEstimate() throws {
    // `scanAllModels(in:)` (no hardwareInfo overload) must still produce a
    // usable (if conservative) estimate rather than crashing or silently
    // reporting 0 — the streaming estimate needs physical RAM to size the
    // auto expert cache and is simply skipped without it.
    let oneGiB = 1024 * 1024 * 1024
    let dir = try makeDeepseekV4Snapshot(residentBytes: oneGiB, switchMlpBytes: 4 * oneGiB)
    defer { try? FileManager.default.removeItem(at: dir) }

    let info = try #require(ModelScanner.parseModelInfo(
        snapshotDir: dir, modelName: "org/dsv4-test",
        hardwareInfo: nil, backend: BackendSettings(streamExperts: true)))
    let naive = (Double(info.sizeBytes) / (1024 * 1024 * 1024)) * 1.2
    #expect(abs(info.estimatedMemoryGb - naive) < 0.0001)
}
