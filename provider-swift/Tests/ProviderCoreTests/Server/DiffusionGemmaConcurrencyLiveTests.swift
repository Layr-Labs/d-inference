import CoreImage
import Darwin
import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import MLXVLM
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionConcurrencyBundleAnchor: NSObject {}

@Suite("DiffusionGemma full-model concurrent HTTP and retirement", .serialized)
struct DiffusionGemmaConcurrencyLiveTests {
  private static let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
  private final class Observations: @unchecked Sendable {
    struct Event: Codable {
      let kind: String
      let value: Int
      let elapsedNanos: UInt64
    }
    private let lock = NSLock()
    private var peak = 0
    private var deltaCounts = [String: Int]()
    private var epoch = DispatchTime.now().uptimeNanoseconds
    private var lastActive = -1
    private var events = [Event]()
    private var compared = 0
    private var mismatches = 0
    func sample(_ count: Int) {
      lock.withLock {
        peak = max(peak, count)
        if count != lastActive {
          events.append(
            .init(
              kind: "native-active", value: count,
              elapsedNanos: DispatchTime.now().uptimeNanoseconds &- epoch))
          lastActive = count
        }
      }
    }
    func sawDelta(_ id: String) { lock.withLock { deltaCounts[id, default: 0] += 1 } }
    func clientEvent(_ kind: String, row: Int) {
      lock.withLock {
        events.append(
          .init(
            kind: kind, value: row,
            elapsedNanos: DispatchTime.now().uptimeNanoseconds &- epoch))
      }
    }
    func compare(_ equal: Bool) {
      lock.withLock {
        compared += 1
        if !equal { mismatches += 1 }
      }
    }
    func allEqual(_ expected: Int) -> Bool {
      lock.withLock { compared == expected && mismatches == 0 }
    }
    var timeline: [Event] { lock.withLock { events } }
    func reset() {
      lock.withLock {
        peak = 0
        deltaCounts.removeAll()
        events.removeAll()
        lastActive = -1
        compared = 0
        mismatches = 0
        epoch = DispatchTime.now().uptimeNanoseconds
      }
    }
    var maximum: Int { lock.withLock { peak } }
    func deltas(_ id: String) -> Int { lock.withLock { deltaCounts[id] ?? 0 } }
  }
  fileprivate final class Owners: @unchecked Sendable {
    weak var container: AnyObject?
    weak var model: AnyObject?
    weak var text: AnyObject?
    weak var decoder: AnyObject?
    var released: Bool { container == nil && model == nil && text == nil && decoder == nil }
  }
  private struct Response: Sendable, Equatable {
    let content: String, reasoning: String, finish: String
    let calls: [String]
    let prompt: Int, completion: Int
    let cached: Int
    func sameInference(as other: Self) -> Bool {
      content == other.content && reasoning == other.reasoning && finish == other.finish
        && calls == other.calls && prompt == other.prompt && completion == other.completion
    }
  }
  /// A real transport abort, not merely cancellation of a client-side body
  /// collector (which can keep/drain an HTTP/1 connection for reuse).
  private final class ResetSocket {
    private var descriptor: Int32 = -1
    init(port: Int, token: String, body: Data) throws {
      descriptor = try Self.connectLoopback(port: port)
      do {
        var noSignal: Int32 = 1
        try #require(
          setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try #require(
          setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        var reset = linger(l_onoff: 1, l_linger: 0)
        try #require(
          setsockopt(
            descriptor, SOL_SOCKET, SO_LINGER, &reset,
            socklen_t(MemoryLayout.size(ofValue: reset))) == 0)
        let header =
          "POST /v1/chat/completions HTTP/1.1\r\nHost: localhost:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(header.utf8) + body
        try payload.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let sent = Darwin.send(
              descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if sent < 0 && errno == EINTR { continue }
            try #require(sent > 0)
            offset += sent
          }
        }
      } catch {
        close()
        throw error
      }
    }
    private static func connectLoopback(port: Int) throws -> Int32 {
      guard (1...65535).contains(port) else { throw POSIXError(.EINVAL) }
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      hints.ai_flags = AI_NUMERICSERV
      var addresses: UnsafeMutablePointer<addrinfo>?
      let status = getaddrinfo("localhost", String(port), &hints, &addresses)
      guard status == 0, let addresses else {
        throw NSError(domain: "DiffusionLoopbackResolution", code: Int(status))
      }
      defer { freeaddrinfo(addresses) }
      var next: UnsafeMutablePointer<addrinfo>? = addresses
      var lastError = ECONNREFUSED
      while let candidate = next {
        let address = candidate.pointee
        next = address.ai_next
        let socket = Darwin.socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        if socket < 0 { lastError = errno; continue }
        if Darwin.connect(socket, address.ai_addr, address.ai_addrlen) == 0 { return socket }
        lastError = errno
        Darwin.close(socket)
      }
      throw POSIXError(POSIXErrorCode(rawValue: lastError) ?? .ECONNREFUSED)
    }

    func close() {
      if descriptor >= 0 {
        Darwin.close(descriptor)
        descriptor = -1
      }
    }
    deinit { close() }
  }
  @Test(arguments: [AF_INET, AF_INET6])
  func resetSocketConnectsToEitherLoopbackFamily(_ family: Int32) throws {
    var hints = addrinfo()
    hints.ai_family = family
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    var addresses: UnsafeMutablePointer<addrinfo>?
    try #require(getaddrinfo(family == AF_INET ? "127.0.0.1" : "::1", "0", &hints, &addresses) == 0)
    let address = try #require(addresses)
    defer { freeaddrinfo(address) }
    let listener = Darwin.socket(family, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { Darwin.close(listener) }
    if family == AF_INET6 {
      var onlyIPv6: Int32 = 1
      try #require(setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIPv6,
        socklen_t(MemoryLayout<Int32>.size)) == 0)
    }
    try #require(Darwin.bind(listener, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0)
    try #require(Darwin.listen(listener, 1) == 0)
    var storage = sockaddr_storage()
    var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
    var service = [CChar](repeating: 0, count: 16)
    try withUnsafeMutablePointer(to: &storage) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try #require(getsockname(listener, $0, &size) == 0)
        try #require(getnameinfo($0, size, nil, 0, &service, socklen_t(service.count), NI_NUMERICSERV) == 0)
      }
    }
    let port = try #require(Int(String(cString: service)))
    let reset = try ResetSocket(port: port, token: "synthetic", body: Data("{}".utf8))
    reset.close()
  }

  private func eventually(_ name: String, _ predicate: @escaping @Sendable () async -> Bool)
    async throws
  {
    let until = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()), ContinuousClock.now < until {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await predicate(), "Timed out waiting for \(name)")
  }
  private static func decode(_ data: Data) throws -> Response {
    let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let choices = try #require(value["choices"] as? [[String: Any]])
    let choice = try #require(choices.first)
    let message = try #require(choice["message"] as? [String: Any])
    let usage = try #require(value["usage"] as? [String: Any])
    let calls = try (message["tool_calls"] as? [[String: Any]] ?? []).map { call -> String in
      let function = try #require(call["function"] as? [String: Any])
      return (try #require(function["name"] as? String)) + "\n"
        + (try #require(function["arguments"] as? String))
    }
    let content = message["content"] as? String ?? ""
    #expect(!content.contains("<|channel>") && !content.contains("<channel|>"))
    return .init(
      content: content, reasoning: message["reasoning_content"] as? String ?? "",
      finish: try #require(choice["finish_reason"] as? String), calls: calls,
      prompt: try #require(usage["prompt_tokens"] as? Int),
      completion: try #require(usage["completion_tokens"] as? Int),
      cached: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0)
  }
  private static func bodies(extendedPrompt: Bool = false) throws -> [Data] {
    let notes =
      extendedPrompt
      ? (1...48).map {
        "Record \($0): Each request keeps its own input and result. Prior records do not change the final instruction."
      }.joined(separator: "\n") + "\n" : ""
    func chat(_ content: Any, seed: Int = 7419, reasoning: Bool = false) -> [String: Any] {
      [
        "model": modelID, "messages": [["role": "user", "content": content]],
        "temperature": 1, "seed": seed, "reasoning": ["enabled": reasoning],
        "max_tokens": 256, "stream": false,
      ]
    }
    let math = chat(notes + "What is 17 times 19? Reply with the number only.", seed: 341)
    func tool(_ reasoning: Bool) -> [String: Any] {
      var body = chat(
        notes + "Use get_weather to check the current weather in Paris. Do not guess the weather.",
        reasoning: reasoning)
      body["tools"] = [
        [
          "type": "function",
          "function": [
            "name": "get_weather",
            "description": "Get the current weather for a city.",
            "parameters": [
              "type": "object",
              "properties": ["city": ["type": "string"]], "required": ["city"],
              "additionalProperties": false,
            ],
          ],
        ]
      ]
      body["tool_choice"] = "required"
      body["parallel_tool_calls"] = false
      return body
    }
    let image = CIImage(color: .blue).cropped(to: .init(x: 0, y: 0, width: 64, height: 64))
    let png = try #require(
      CIContext().pngRepresentation(
        of: image, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    let media = chat(
      [
        [
          "type": "image_url",
          "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()],
        ],
        [
          "type": "text",
          "text": notes
            + "Name the single dominant color of this image. Reply using only the color name.",
        ],
      ], seed: 8132)
    return try [math, tool(false), tool(true), media].map {
      try JSONSerialization.data(withJSONObject: $0)
    }
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_CONCURRENCY_HTTP_LIVE"] == "1"))
  func mixedRequestsQuietDisconnectAndReloadPreserveIsolatedResults() async throws {
    try await exercise(cached: false)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_CACHE_CONCURRENCY_LIVE"] == "1"))
  func encryptedCacheToolsAndMixedCohortsPreserveColdResultsAndCancellation() async throws {
    try await exercise(cached: true)
  }

  /// A separate sustained-overlap cell. Keep the original short-prompt gate
  /// and its failures visible; launching four short tasks does not guarantee
  /// four native sessions coexist after heterogeneous media preparation.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_UNCACHED_PREFILL_COHORT_LIVE"]
        == "1"))
  func uncachedPrefillCohortsPreserveIsolatedResultsAndCancellation() async throws {
    try #require(ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE"] == "0")
    try await exercise(cached: false, extendedPrompt: true)
  }

  private func exercise(cached: Bool, extendedPrompt: Bool = false) async throws {
    let selectedPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]
    let selected = URL(fileURLWithPath: try #require(selectedPath))
    let directory = try #require(ModelScanner.resolveLocalPath(modelID: Self.modelID))
    try #require(
      directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
        == selected.appendingPathComponent("config.json").resolvingSymlinksInPath())
    try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
    _ = Bundle(for: DiffusionConcurrencyBundleAnchor.self).bundleURL
    if cached {
      let environment = ProcessInfo.processInfo.environment
      let memoryEnabled = PrefixCachePolicy.isMemoryEnabled(environment: environment)
      let diskEnabled = PrefixCachePolicy.isEnabled(modelId: Self.modelID, environment: environment)
      let ephemeral = SSDPrefixCacheFactory.forceEphemeralKey(environment: environment)
      try #require(!memoryEnabled && diskEnabled && ephemeral)
      let resources = try #require(Bundle(for: DiffusionConcurrencyBundleAnchor.self).resourceURL)
      let library = resources.appendingPathComponent(
        "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
      let expected = try #require(hashFile(atPath: library.path))
      try #require(
        bindRuntimeMetallibForMLX(from: library) == expected && metallibHash() == expected)
    }
    let beforeActive = Memory.activeMemory
    let hash = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID))
    try #require(hash == "2ad9d4a10fe791e9e74a6475298c048e9da2d3df9e049eeb37a9d98055fcc2ce")
    let model = try #require(
      ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.modelID))
    let token = UUID().uuidString + UUID().uuidString
    let server = StandaloneServer(
      config: .init(
        authToken: token, engineV2KVBackend: "paged",
        coordinatorURL: "http://127.0.0.1:1"), models: [model])
    await server.activateDiffusionRouterHarness()
    let observations = Observations()
    let bodies = try Self.bodies(extendedPrompt: cached || extendedPrompt)
    do {
      try await server.ensureModelLoaded(Self.modelID)
      try await server.observeConcurrentDiffusion(Self.modelID) { id, _ in observations.sawDelta(id)
      }
      // Multi-connection HTTP client, loopback ephemeral port. Loading is
      // outside its bounded per-request timeout; this is not cold TTFT.
      try await server.makeApplication().test(.ahc()) { client in
        try #require(client.port != nil)
        @Sendable func request(_ body: Data) async throws -> Response {
          let response = try await client.execute(
            uri: "/v1/chat/completions", method: .post,
            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
            body: ByteBuffer(data: body))
          try #require(
            response.status == .ok, "Synthetic native request rejected: \(response.status)")
          return try Self.decode(Data(response.body.readableBytesView))
        }
        var references = [Response]()
        if cached {
          // Close only this test-owned store. All baseline requests
          // still use normal authenticated serving, but cannot read
          // or publish a cache entry. RAM retention is also disabled.
          let coldStore = try #require(await server.diffusionPrefixTestStore(Self.modelID))
          await coldStore.closeAndWait()
        }
        for body in bodies { references.append(try await request(body)) }
        if cached || extendedPrompt {
          #expect(references.allSatisfy { $0.cached == 0 && $0.prompt > 1024 })
        }
        #expect(references[0].content.contains("323"))
        for index in [1, 2] {
          #expect(references[index].finish == "tool_calls" && references[index].calls.count == 1)
          #expect(references[index].calls.first == "get_weather\n{\"city\":\"Paris\"}")
        }
        #expect(
          references[1].reasoning.isEmpty && references[3].content.lowercased().contains("blue"))
        if cached {
          try await eventually("cold reference requests actually retired") {
            await server.debugActiveRequestCount(modelId: Self.modelID) == 0
          }
          try #require(await server.evictLRUIdleSlotForTesting())
          try await server.ensureModelLoaded(Self.modelID)
          try await server.observeConcurrentDiffusion(Self.modelID) { id, _ in
            observations.sawDelta(id)
          }
          let store = try #require(await server.diffusionPrefixTestStore(Self.modelID))
          try #require(store.usesEphemeralKey)
          for (index, body) in bodies.enumerated() {
            let donor = try await request(body)
            #expect(donor.sameInference(as: references[index]))
            await store.waitForWritesForTesting()
            let repeatResult = try await request(body)
            #expect(repeatResult.sameInference(as: references[index]) && repeatResult.cached > 0)
            print(
              "DIFFUSION_CACHE_TOOL row=\(index) prompt=\(repeatResult.prompt) cached=\(repeatResult.cached) coldEquality=\(repeatResult.sameInference(as: references[index]))"
            )
          }
          await store.waitForWritesForTesting()
        }
        for order in [[0, 1], [3, 2, 1, 0]] {
          observations.reset()
          defer {
            let row: [String: Any] = [
              "order": order, "encryptedCache": cached,
              "extendedPrompt": extendedPrompt, "observed": observations.maximum,
              "isolatedEquality": observations.allEqual(order.count),
              "events":
                (try? JSONSerialization.jsonObject(
                  with: JSONEncoder().encode(observations.timeline))) ?? [],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
              print("DIFFUSION_COHORT_TIMELINE " + String(decoding: data, as: UTF8.self))
            }
          }
          let monitor = Task {
            while !Task.isCancelled {
              observations.sample(
                await server.nativeConcurrentCapacity(Self.modelID)?.activeRequests ?? 0)
              try? await Task.sleep(for: .milliseconds(2))
            }
          }
          do {
            try await withThrowingTaskGroup(of: (Int, Response).self) { group in
              for index in order {
                group.addTask {
                  observations.clientEvent("http-start", row: index)
                  defer { observations.clientEvent("http-finish", row: index) }
                  return (index, try await request(bodies[index]))
                }
              }
              for try await (index, actual) in group {
                let matches = actual.sameInference(as: references[index])
                observations.compare(matches)
                #expect(matches)
                if cached { #expect(actual.cached > 0) }
              }
            }
          } catch {
            monitor.cancel()
            await monitor.value
            throw error
          }
          monitor.cancel()
          await monitor.value
          #expect(observations.maximum >= order.count, "Observe actual overlapping native sessions")
          print(
            "DIFFUSION_CONCURRENCY rows=\(order.count) observed=\(observations.maximum) isolatedEquality=\(observations.allEqual(order.count)) encryptedCache=\(cached) extendedPrompt=\(extendedPrompt) fusedBatchClaim=false"
          )
        }
        try await eventually("HTTP cohorts fully retired") {
          await server.debugActiveRequestCount(modelId: Self.modelID) == 0
        }
        observations.reset()
        var beforeQuietWrites: UInt64?
        if cached {
          let store = try #require(await server.diffusionPrefixTestStore(Self.modelID))
          await store.waitForWritesForTesting()
          beforeQuietWrites = UInt64(store.stats().filesWritten)
        }
        let longPrompt = (1...220).map { i in
          "Section \(i): Each request owns its cache and native canvas. Cancellation must release only its own state. Preserve the surviving request's exact result."
        }.joined(separator: "\n")
        let longBody = try JSONSerialization.data(withJSONObject: [
          "model": Self.modelID,
          "messages": [
            ["role": "user", "content": longPrompt + "\nExplain these rules in detail."]
          ],
          "temperature": 1, "seed": 341, "reasoning": ["enabled": false], "max_tokens": 512,
          "stream": true,
        ])
        let longTokens = try await server.concurrentPromptTokens(Self.modelID, body: longBody)
        let cancelled = try ResetSocket(
          port: try #require(client.port), token: token, body: longBody)
        do {
          try await eventually("real quiet prefill") {
            guard let snapshot = await server.nativeConcurrentCapacity(Self.modelID) else {
              return false
            }
            return snapshot.activeRequests == 1 && snapshot.activeTokens >= 1024
              && snapshot.activeTokens < longTokens
          }
          let id = try #require(await server.onlyConcurrentProviderID(Self.modelID))
          #expect(observations.deltas(id) == 0)
          let survivor = Task { try await request(bodies[0]) }
          try await eventually("survivor joined native quiet prefill") {
            await server.nativeConcurrentCapacity(Self.modelID)?.activeRequests == 2
          }
          let quiet = try #require(await server.nativeConcurrentCapacity(Self.modelID))
          try #require(
            quiet.activeTokens < longTokens && observations.deltas(id) == 0,
            "Do not relabel a decode cancellation as quiet prefill")
          cancelled.close()
          #expect(try await survivor.value.sameInference(as: references[0]))
          try await eventually("cancelled row and survivor retired") {
            await server.debugActiveRequestCount(modelId: Self.modelID) == 0
          }
          #expect(
            observations.deltas(id) == 0, "Quiet cancellation must not expose a provisional canvas")
          if let beforeQuietWrites {
            let store = try #require(await server.diffusionPrefixTestStore(Self.modelID))
            await store.waitForWritesForTesting()
            #expect(
              UInt64(store.stats().filesWritten) == beforeQuietWrites,
              "Canceled prefill must not publish a new donor; survivor reuses an existing entry")
          }
          print(
            "DIFFUSION_CONCURRENCY transportReset=true promptTokens=\(longTokens) activeAtReset=\(quiet.activeTokens) concurrentAtReset=\(quiet.activeRequests)"
          )
        } catch {
          cancelled.close()
          throw error
        }

        let owners = try await server.concurrentOwnerWitnesses(Self.modelID)
        let oldBridge = try #require(await server.concurrentBridge(Self.modelID))
        try #require(await server.evictLRUIdleSlotForTesting())
        try await eventually("outer and inner native model owners released") { owners.released }
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
        let afterUnload = Memory.activeMemory
        #expect(
          afterUnload <= beforeActive + (1 << 30),
          "Drop weights, not just the wrapper, before reload")
        try await server.ensureModelLoaded(Self.modelID)
        let newBridge = try #require(await server.concurrentBridge(Self.modelID))
        #expect(newBridge !== oldBridge)
        let reloaded = try await request(bodies[0])
        #expect(reloaded.sameInference(as: references[0]))
        if cached {
          #expect(
            reloaded.cached == 0,
            "New ephemeral key reload is cold, not persistent-key restart proof")
        }
        print(
          "DIFFUSION_CONCURRENCY quietCancel=true survivorExact=true retainedOldBridge=true innerOwnersReleased=true reloadExact=true activeBefore=\(beforeActive) activeAfterUnload=\(afterUnload)"
        )
      }
      #expect(WeightHasher.computeHash(snapshotDir: directory, modelID: Self.modelID) == hash)
    } catch {
      await server.stopAndWait()
      throw error
    }
    await server.stopAndWait()
    #expect(await server.debugOutstandingKVReservationBytes() == 0)
  }
}

extension StandaloneServer {
  fileprivate func nativeConcurrentCapacity(_ modelID: String) async -> CBv2CapacitySnapshot? {
    guard let bridge = slots[modelID]?.bridge else { return nil }
    return await bridge.nativeConcurrentCapacity()
  }
  fileprivate func observeConcurrentDiffusion(
    _ modelID: String, observer: @escaping @Sendable (String, String) -> Void
  ) async throws {
    let bridge = try #require(slots[modelID]?.bridge)
    await bridge.observeConcurrentDiffusion(observer)
  }
  fileprivate func onlyConcurrentProviderID(_ modelID: String) async -> String? {
    guard let bridge = slots[modelID]?.bridge else { return nil }
    return await bridge.onlyConcurrentProviderID()
  }
  fileprivate func concurrentBridge(_ modelID: String) -> EngineV2Bridge? { slots[modelID]?.bridge }
  fileprivate func concurrentPromptTokens(_ modelID: String, body: Data) async throws -> Int {
    let container = try #require(slots[modelID]?.modelContainer.diffusion)
    return try await container.perform { context in
      try ProviderPromptContractPipeline.tokenizeProviderBody(
        body,
        tokenizer: context.tokenizer, modelType: "diffusion_gemma"
      ).count
    }
  }
  fileprivate func concurrentOwnerWitnesses(_ modelID: String) async throws
    -> DiffusionGemmaConcurrencyLiveTests.Owners
  {
    let container = try #require(slots[modelID]?.modelContainer.diffusion)
    let witnesses = await container.perform { context in
      let result = DiffusionGemmaConcurrencyLiveTests.Owners()
      result.model = context.model
      result.text = context.model.model
      result.decoder = context.model.model.decoder
      return result
    }
    witnesses.container = container
    return witnesses
  }
}
extension EngineV2Bridge {
  fileprivate func nativeConcurrentCapacity() -> CBv2CapacitySnapshot? {
    (ownedEngine as? CBv2NativeBlockEngine)?.capacity()
  }
  fileprivate func onlyConcurrentProviderID() -> String? {
    active.count == 1 ? active.keys.first : nil
  }
  fileprivate func observeConcurrentDiffusion(
    _ observer: @escaping @Sendable (String, String) -> Void
  ) { _testNativeTextObserver = observer }
}
