// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// `DARKBLOOM_INKLING_FOLD_SYSTEM`: an off word renders Inkling 2's later
/// system turns in place again, as its template does.
@Suite("Inkling 2 system-turn fold switch")
struct Inkling2SystemFoldSwitchTests {
    @Test func offWordsTurnTheFoldOff() {
        #expect(Inkling2PromptContract.foldSystemEnvironmentKey == "DARKBLOOM_INKLING_FOLD_SYSTEM")
        for value in [nil, "", "1", "on", "true", " yes "] as [String?] {
            #expect(Inkling2PromptContract.isFoldEnabled(value), "\(String(describing: value))")
        }
        for value in ["0", "false", "OFF", " no "] {
            #expect(!Inkling2PromptContract.isFoldEnabled(value), "\(value)")
        }
    }

    @Test func offKeepsLaterSystemTurnsInPlace() {
        let messages: [[String: any Sendable]] = [
            ["role": "system", "content": "S0"], ["role": "user", "content": "Hi"], ["role": "system", "content": "S1"],
        ]
        let kept = Inkling2PromptContract.normalizeSystemMessages(messages, enabled: false)
        #expect(kept.map { $0["role"] as? String } == ["system", "user", "system"])
        #expect(kept.map { $0["content"] as? String } == ["S0", "Hi", "S1"])
        let folded = Inkling2PromptContract.normalizeSystemMessages(messages, enabled: true)
        #expect(folded.map { $0["role"] as? String } == ["system", "user"])
        #expect(folded.first?["content"] as? String == "S0\n\nS1")
        let typed: [OpenAIChatMessage] = [
            .init(role: .user, content: .text("Hi")), .init(role: .system, content: .text("S1")),
        ]
        #expect(Inkling2PromptContract.normalizeSystemMessages(typed, enabled: false).map(\.role) == [.user, .system])
        #expect(Inkling2PromptContract.normalizeSystemMessages(typed, enabled: true).map(\.role) == [.system, .user])
    }
}
