/// Environment variable scrubbing to prevent library injection and debugging.

import Foundation
import os

private let envLogger = Logger(subsystem: "dev.darkbloom.provider", category: "security")

/// Dangerous environment variables that could enable library injection,
/// path hijacking, or process inspection.
private let dangerousEnvVars: [String] = [
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "LD_PRELOAD",
    "MallocStackLogging",
    "MallocStackLoggingNoCompact",
    "MallocScribble",
    "MallocGuardEdges",
    "MallocLogFile",
    "MallocErrorAbort",
    "NSZombieEnabled",
    "OBJC_DEBUG_POOL_ALLOCATION",
    "CFNETWORK_DIAGNOSTICS",
]

/// Scrub environment variables that could enable library injection or
/// debugging of this process or its children.
///
/// Called once at startup before any sensitive data is loaded. Unlike the
/// Rust provider, Python-specific vars (PYTHONPATH, etc.) are not relevant
/// since the Swift provider does not spawn a Python runtime.
public func scrubDangerousEnvironment() {
    for name in dangerousEnvVars {
        if ProcessInfo.processInfo.environment[name] != nil {
            envLogger.warning("Scrubbing dangerous env var: \(name, privacy: .public)")
            unsetenv(name)
        }
    }
}
