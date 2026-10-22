import Foundation
import Darwin
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// `darkbloom cluster local` (2026-10-15): how the cluster serves is kept in the setup record on a real owner-only
    /// directory until changed; a record written by an older build reads as public; an address the API does not take
    /// falls back to loopback, never to a wider exposure. Failing first on 69ba75be7 (no scope in the record).
    static func servingScopeInTheRecord() throws {
        let home = scratch.appendingPathComponent("scope-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = ClusterSetupStore(paths: .init(paths: try ClusterUserPaths(homeDirectory: home)))
        let leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: String(repeating: "a", count: 64),
                                                     peerPin: String(repeating: "b", count: 64), peerName: "Apple M4 Max, 128 GB", since: "t0")
        try store.updateRecord { $0.leadership = leadership }
        expectEqual(try store.readRecord().leadership?.scope, .publicServing, "a new pairing serves through Darkbloom")

        try store.updateRecord { $0.leadership?.scope = .localOnly(bind: "0.0.0.0") }
        let saved = try store.readRecord().leadership
        expectEqual(saved?.scope, .localOnly(bind: "0.0.0.0"), "local only is kept with its address")
        expectEqual(saved?.localOnly, true, "the record's own field says local only")
        try store.updateRecord { $0.leadership?.serving = true; $0.leadership?.modelName = "Qwen3.5-9B" }
        expectEqual(try store.readRecord().leadership?.scope, .localOnly(bind: "0.0.0.0"), "a start keeps the scope (kept until changed)")

        try store.updateRecord { $0.leadership?.scope = .publicServing }
        let back = try store.readRecord().leadership
        expect(back?.scope == .publicServing && back?.localOnly == nil && back?.localBind == nil, "back to public leaves no local-only field")

        // Written by an older build: no scope fields at all.
        let older = #"{"schema":"darkbloom_cluster_setup_wizard_v1","confirmed":[],"sent":[],"checks":[],"leadership":{"role":"leader","leaderPin":"a","peerPin":"b","peerName":"Apple M4 Max, 128 GB","since":"t0","serving":true,"modelName":"Qwen3.5-9B"}}"#
        try Data(older.utf8).write(to: store.paths.record)
        expectEqual(try store.readRecord().leadership?.scope, .publicServing, "an older record reads as public")

        // An address no API takes (edited by hand): loopback, never every interface.
        let edited = older.replacingOccurrences(of: #""serving":true"#, with: #""serving":true,"localOnly":true,"localBind":"my-mac.local""#)
        try Data(edited.utf8).write(to: store.paths.record)
        expectEqual(try store.readRecord().leadership?.scope, .localOnly(bind: "127.0.0.1"), "an address the API does not take falls back to loopback")
        try FileManager.default.removeItem(at: store.paths.record)
    }
}
