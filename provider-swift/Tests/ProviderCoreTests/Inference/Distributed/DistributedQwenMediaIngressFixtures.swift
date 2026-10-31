import CoreGraphics
import Foundation
import ImageIO
import MLXLMCommon

// Generated deterministic red/blue 224px fixtures. The MP4 contains red for
// two seconds then blue for two seconds at two frames/second, no audio.
// These are processor fixtures, not language-model capability evidence.
enum QwenIngressFixtures {
    static let red = "iVBORw0KGgoAAAANSUhEUgAAAOAAAADgCAIAAACVT/22AAACoElEQVR4nO3OMQ3AQBAEseNP+sNg20lhyQB87w5+qx/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgDDB9KgR25apIDpAAAAAElFTkSuQmCC"
    static let blue = "iVBORw0KGgoAAAANSUhEUgAAAOAAAADgCAIAAACVT/22AAACoElEQVR4nO3OQQ2AABAEsfNvGhSw3+HRpAJ6dw/8WD+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QCGfgBDP4ChH8DQD2DoBzD0Axj6AQz9AIZ+AEM/gKEfwNAPYOgHMPQDGPoBDP0Ahn4AQz+AoR/A0A9g6Acw9AMY+gEM/QA+vUPGR252103GAAAAAElFTkSuQmCC"
    static let video = "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAOObW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAD6AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAArl0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAOAAAADgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAA+gAABAAAABAAAAAAIxbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAABAABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB3G1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZxzdGJsAAAAwHN0c2QAAAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAOAA4ABIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAL/+EAGWdkAAus2UOHbARAAAADAEAAAAMBA8UKZYABAAZo6+PLIsD9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAByAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAgAACAAAAAAGHN0c3MAAAAAAAAAAgAAAAEAAAAFAAAAQGN0dHMAAAAAAAAABgAAAAEAAEAAAAAAAQAAgAAAAAACAAAgAAAAAAEAAEAAAAAAAQAAgAAAAAACAAAgAAAAABxzdHNjAAAAAAAAAAEAAAABAAAACAAAAAEAAAA0c3RzegAAAAAAAAAAAAAACAAAAvMAAAARAAAADgAAAA4AAABDAAAAEQAAAA4AAAAOAAAAFHN0Y28AAAAAAAAAAQAAA74AAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAyAAAACGZyZWUAAAOYbWRhdAAAAq0GBf//qdxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0xIHJlZj0zIGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgxMTMgbWU9aGV4IHN1Ym1lPTcgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MSBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTEgOHg4ZGN0PTEgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9LTIgdGhyZWFkcz03IGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiX2FkYXB0PTEgYl9iaWFzPTAgZGlyZWN0PTEgd2VpZ2h0Yj0xIG9wZW5fZ29wPTAgd2VpZ2h0cD0yIGtleWludD0yNTAga2V5aW50X21pbj0yIHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAPmWIhAAV//7sz34FNmjmL8PxRXOOfHXjmNOmhniur/TeoXEYw5DI2X2k1qerF7KEhdgAAFTAFfP6J8yzkeRzAAAADUGaI2xBL/61KoAA0IAAAAAKQZ5BeIJ/AABEwQAAAAoBnmJqQS8AAGfAAAAAP2WIggAF//7ugr4FN1/ED8M88frQIVz46oL00N8V1f6b1C4jGHIZKPvElKD84vZQkOAAAAmwAySbYfqwQznf4QAAAA1BmiNsQS/+tSqAANCBAAAACkGeQXiCfwAARMEAAAAKAZ5iakEvAABnwQ=="
}

extension QwenIngressFixtures {
    /// A base64 solid red PNG of any size: geometry for the processor's
    /// resize bounds, not image content.
    static func redPNG(width: Int, height: Int) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
    }
}

struct QwenIngressTokenizer: Tokenizer {
    var completionPieces: [Int: String] = [:]
    var templateCapture: QwenIngressTemplateCapture? = nil
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        let markers = ["<|image_pad|>", "<|video_pad|>", "<|vision_start|>", "<|vision_end|>"]
        var rest = text[...], result: [Int] = []
        while !rest.isEmpty {
            if let marker = markers.first(where: { rest.hasPrefix($0) }) {
                result.append(convertTokenToId(marker)!); rest = rest.dropFirst(marker.count)
            } else { result.append(3); rest = rest.dropFirst() }
        }
        return result
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        completionPieces.isEmpty ? tokenIds.map(String.init).joined(separator: ",")
            : tokenIds.compactMap { completionPieces[$0] }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        ["<|image_pad|>": 60, "<|video_pad|>": 61, "<|vision_start|>": 57, "<|vision_end|>": 58][token]
    }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        templateCapture?.record(messages)
        var tokens = [1]
        for message in messages {
            for part in message["content"] as? [[String: String]] ?? [] {
                if part["type"] == "image" { tokens += [57, 60, 58] }
                if part["type"] == "video" { tokens += [57, 61, 58] }
            }
        }
        return tokens + [2]
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] {
        try applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
    }
}

@testable import ProviderCore
import DarkbloomClusterProtocol

/// Fabricated native completion only. It proves bridge custody, not media
/// capability, native allocation or a physical peer's retirement.
final class QwenIngressOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let profile: DistributedResidentExecutionProfile
    let contract: String?
    private let lock = NSLock()
    private var values: [QwenIngressLease] = []
    var concurrentRequests: Int { 2 }
    var leases: [QwenIngressLease] { lock.withLock { values } }
    init(configuration: Data, contract: String? = ClusterQwenMedia.contract,
        modelID: String = "registered_qwen38_27b") throws {
        self.contract = contract
        identity = .init(membershipEpoch: UUID(), modelID: modelID,
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: ClusterQwenMedia.sha256(configuration),
            peers: [.init(id: "fixture-rank0", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "fixture-rank1", buildSHA256: String(repeating: "d", count: 64))])
        profile = try .init(id: "registered_qwen38_27b_greedy_generation_v1", vocabularySize: 64,
            maxPromptTokens: 1024, maxOutputTokens: 8, maxContextTokens: 1032,
            requestTimeout: .seconds(10), supportsLogprobs: true)
    }
    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: profile.id, requestCapacityBytes: 1 << 20, media: contract)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork { .unbounded(reason: nil) }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String,
        capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        let lease = QwenIngressLease(identity: identity, request: request)
        lock.withLock { values.append(lease) }
        return lease
    }
    func shutdown() async {}
}
final class QwenIngressLease: DistributedResidentRequestLease, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    let reservedBytes = 64
    var bytesInUse: Int { 0 } // no native allocations in this fixture
    private let lock = NSLock()
    private let retired = DistributedRetirementLatch()
    private var request: CBv2Request?
    private var emit: (@Sendable (DistributedResidentEvent) -> Bool)?
    private var released = 0
    init(identity: DistributedResidentIdentity, request: CBv2Request) {
        self.identity = identity; requestID = request.id; self.request = request
    }
    var holdsWire: Bool { lock.withLock { request?.clusterQwenMedia != nil } }
    var releases: Int { lock.withLock { released } }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws { lock.withLock { self.emit = emit } }
    func send(_ event: DistributedResidentEvent) { _ = lock.withLock { emit }?(event) }
    func cancel() {}
    func acknowledge() { retired.complete() }
    func waitUntilRetired() async { await retired.wait() }
    func releaseResources() { lock.withLock { request = nil; emit = nil; released += 1 } }
}

actor QwenIngressReleaseCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Observes actual template inputs without inferring model output correctness.
final class QwenIngressTemplateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ messages: [[String: any Sendable]]) {
        lock.withLock { values.append(String(describing: messages)) }
    }
    var descriptions: [String] { lock.withLock { values } }
}
