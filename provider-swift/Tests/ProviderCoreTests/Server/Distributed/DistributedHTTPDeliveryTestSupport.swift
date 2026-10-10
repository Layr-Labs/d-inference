import Foundation
import Hummingbird
import HTTPTypes
import MLXLMServer
import NIOCore
@testable import ProviderCore

/// In-memory writer only; acceptance here is deliberately not network receipt.
final class HTTPDeliveryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []
    private var finishes = 0
    private var cancellations = 0
    var values: [String] { lock.withLock { frames } }
    var finishCount: Int { lock.withLock { finishes } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func append(_ text: String) { lock.withLock { frames.append(text) } }
    func finish() { lock.withLock { finishes += 1 } }
    func cancel() { lock.withLock { cancellations += 1 } }
}

struct HTTPDeliveryWriter: ResponseBodyWriter {
    let capture: HTTPDeliveryCapture
    var beforeWrite: @Sendable (String) async throws -> Void = { _ in }
    mutating func write(_ buffer: ByteBuffer) async throws {
        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
        try await beforeWrite(text)
        try Task.checkCancellation()
        capture.append(text)
    }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws { capture.finish() }
}

func httpDeliveryFrame(content: String? = nil, reasoning: String? = nil, role: String? = nil,
                       finish: String? = nil) throws -> String {
    try ServerSentEventEncoder.encode(OpenAIChatCompletionChunk(id: "fixture", model: "fixture",
        choices: [.init(index: 0, delta: .init(role: role, content: content,
            reasoningContent: reasoning, toolCalls: nil), finishReason: finish)], usage: nil, created: 1))
}

func httpDeliveryEventually(_ predicate: () -> Bool) async throws -> Bool {
    let end = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < end {
        if predicate() { return true }
        try await Task.sleep(for: .milliseconds(2))
    }
    return predicate()
}
