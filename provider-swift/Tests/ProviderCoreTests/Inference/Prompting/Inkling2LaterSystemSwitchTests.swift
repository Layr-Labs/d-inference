// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// `DARKBLOOM_INKLING_LATER_SYSTEM_AS_USER`: an off word renders Inkling 2's
/// later system turns as system again, as its template does.
@Suite("Inkling 2 later system turn switch")
struct Inkling2LaterSystemSwitchTests {
    @Test func offWordsTurnItOff() {
        #expect(Inkling2PromptContract.laterSystemEnvironmentKey == "DARKBLOOM_INKLING_LATER_SYSTEM_AS_USER")
        for value in [nil, "", "1", "on", "true", " yes "] as [String?] {
            #expect(Inkling2PromptContract.isLaterSystemAsUserEnabled(value), "\(String(describing: value))")
        }
        for value in ["0", "false", "OFF", " no "] {
            #expect(!Inkling2PromptContract.isLaterSystemAsUserEnabled(value), "\(value)")
        }
    }

    @Test func offKeepsLaterSystemTurnsAsSystem() {
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "S0"], ["role": "user", "content": "Hi"], ["role": "system", "content": "S1"],
        ]
        #expect(Inkling2PromptContract.normalizeSystemMessages(messages, enabled: false).map { $0["role"] as? String }
            == ["system", "user", "system"])
        let changed = Inkling2PromptContract.normalizeSystemMessages(messages, enabled: true)
        #expect(changed.map { $0["role"] as? String } == ["system", "user", "user"])
        #expect(changed.map { $0["content"] as? String } == ["S0", "Hi", "S1"])
        let typed: [OpenAIChatMessage] = [
            .init(role: .user, content: .text("Hi")), .init(role: .system, content: .text("S1")),
        ]
        #expect(Inkling2PromptContract.normalizeSystemMessages(typed, enabled: false).map(\.role) == [.user, .system])
        #expect(Inkling2PromptContract.normalizeSystemMessages(typed, enabled: true).map(\.role) == [.user, .user])
    }
}
