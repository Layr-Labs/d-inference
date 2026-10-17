import Foundation
import NIOCore

/// Task-local scope carrying the application's actual channel to the
/// distributed response layer; nil on every ordinary local engine.
/// Split from PR 1226's LocalConnectionResponder.swift (head 78397f4c): the
/// scope is bound by LocalDisconnectResponder when observation is enabled.
enum LocalHTTPConnectionScope {
    @TaskLocal static var current: (any Channel)?
}
