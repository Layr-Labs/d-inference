// Copyright © 2026 Eigen Labs.
//
// The single source of truth for every unified-logging subsystem the
// provider stack writes to. `darkbloom report` and `darkbloom logs` build
// their `/usr/bin/log` predicates from THIS list — a collector predicate
// naming only one subsystem silently loses every other component's lines
// (the v0.7.13 incident: reports carried zero KVCacheSSD/engine-bridge
// output). A drift test scans Sources for `subsystem:` literals and fails
// if a new subsystem is not registered here.

import Foundation

public enum ProviderLogSubsystems {
    /// Every subsystem any provider-stack component logs to:
    /// - `dev.darkbloom.provider`: ProviderLoop, CoordinatorClient,
    ///   Security, Telemetry, legacy KVCache.
    /// - `com.darkbloom.provider`: all of KVCacheSSD (factory, cache, block
    ///   store, write-behind) and the EngineV2 bridge/logprobs.
    /// - `io.darkbloom.provider`: the CLI's fan-activity lease.
    /// - `io.darkbloom.fan`: the DarkbloomFanHelper daemon.
    public static let all: [String] = [
        "dev.darkbloom.provider",
        "com.darkbloom.provider",
        "io.darkbloom.provider",
        "io.darkbloom.fan",
    ]

    /// NSPredicate source for `/usr/bin/log show|stream --predicate`
    /// matching every provider subsystem. Note `log show` only returns what
    /// the log store persisted: .notice/.warning/.error lines persist to
    /// disk by default, while .info/.debug live in the memory ring buffer
    /// only — low-frequency lifecycle lines that reports must capture are
    /// logged at .notice for exactly this reason.
    public static func unifiedLogPredicate() -> String {
        all.map { #"subsystem == "\#($0)""# }
            .joined(separator: " OR ")
    }
}
