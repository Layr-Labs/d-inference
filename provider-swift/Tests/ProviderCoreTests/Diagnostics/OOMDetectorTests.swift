import Testing
import Foundation
@testable import ProviderCore

// MARK: - Jetsam report parsing

private let jetsamReport = """
{"timestamp":"2026-06-12 05:00:00.00 +0000","bug_type":"298","os_version":"macOS 26.4"}
{"pageSize":16384,"largestProcess":"darkbloom","processes":[{"name":"WindowServer","pid":111,"rpages":1000,"reason":"vm-pageshortage"},{"name":"darkbloom","pid":456,"rpages":1572864,"reason":"per-process-limit"}]}
"""

@Test func oomParsesJetsamReportForOurProcess() {
    let finding = OOMDetector.parseJetsamReport(contents: jetsamReport, processName: "darkbloom")
    #expect(finding != nil)
    #expect(finding?.source == .jetsamReport)
    #expect(finding?.reason == "per-process-limit")
    // 1_572_864 rpages * 16_384 page size = 24 GiB.
    #expect(finding?.peakMemoryBytes == UInt64(1_572_864) * 16_384)
}

@Test func oomJetsamReportIgnoresUnrelatedProcesses() {
    let other = """
    {"bug_type":"298"}
    {"pageSize":16384,"processes":[{"name":"WindowServer","pid":111,"rpages":1000,"reason":"vm-pageshortage"}]}
    """
    #expect(OOMDetector.parseJetsamReport(contents: other, processName: "darkbloom") == nil)
}

@Test func oomJetsamReportToleratesGarbage() {
    #expect(OOMDetector.parseJetsamReport(contents: "not json at all", processName: "darkbloom") == nil)
    #expect(OOMDetector.parseJetsamReport(contents: "", processName: "darkbloom") == nil)
}

/// darkbloom merely PRESENT in the process table (no kill reason, not the
/// largest process) when something else was jetsammed must NOT be reported as a
/// provider OOM.
@Test func oomJetsamReportRequiresKillEvidenceForOurProcess() {
    let safariKilled = """
    {"bug_type":"298"}
    {"pageSize":16384,"largestProcess":"Safari","processes":[{"name":"Safari","pid":111,"rpages":2000,"reason":"per-process-limit"},{"name":"darkbloom","pid":456,"rpages":500}]}
    """
    #expect(OOMDetector.parseJetsamReport(contents: safariKilled, processName: "darkbloom") == nil)

    // But if darkbloom is the largestProcess (a kill signal) it IS reported,
    // even without an explicit per-entry reason.
    let darkbloomLargest = """
    {"bug_type":"298"}
    {"pageSize":16384,"largestProcess":"darkbloom","processes":[{"name":"darkbloom","pid":456,"rpages":1000}]}
    """
    #expect(OOMDetector.parseJetsamReport(contents: darkbloomLargest, processName: "darkbloom")?.source == .jetsamReport)
}

// MARK: - EXC_RESOURCE / jetsam crash report parsing

@Test func oomParsesExcResourceMemoryCrash() {
    let report = """
    {"app_name":"darkbloom","timestamp":"2026-06-12 05:00:00.00 +0000","bug_type":"309"}
    {"exception":{"type":"EXC_RESOURCE","subtype":"MEMORY (fatal)"}}
    """
    let finding = OOMDetector.parseMemoryCrashReport(contents: report, processName: "darkbloom")
    #expect(finding?.source == .memoryCrashReport)
    #expect(finding?.reason == "MEMORY (fatal)")
}

@Test func oomParsesJetsamTerminationCrash() {
    let report = """
    {"app_name":"darkbloom","bug_type":"309"}
    {"termination":{"namespace":"JETSAM","indicator":"per-process-limit"}}
    """
    let finding = OOMDetector.parseMemoryCrashReport(contents: report, processName: "darkbloom")
    #expect(finding?.source == .memoryCrashReport)
    #expect(finding?.reason == "per-process-limit")
}

@Test func oomCrashReportIgnoresOtherAppsAndNonMemoryCrashes() {
    // Different app.
    let otherApp = """
    {"app_name":"Safari","bug_type":"309"}
    {"exception":{"type":"EXC_RESOURCE","subtype":"MEMORY"}}
    """
    #expect(OOMDetector.parseMemoryCrashReport(contents: otherApp, processName: "darkbloom") == nil)
    // Our app but a non-memory crash (e.g. bad access) — not an OOM.
    let segfault = """
    {"app_name":"darkbloom","bug_type":"309"}
    {"exception":{"type":"EXC_BAD_ACCESS","subtype":"KERN_INVALID_ADDRESS"}}
    """
    #expect(OOMDetector.parseMemoryCrashReport(contents: segfault, processName: "darkbloom") == nil)
}

// MARK: - Marker round-trip

@Test func oomMarkerWriteReadClear() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("oom-marker-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let marker = OOMDetector.Marker(
        pid: 4242, epochSeconds: 1_780_000_000, peakMemoryBytes: 25_769_803_776,
        availableBytesAtEvent: 1_000_000, modelId: "gpt-oss-20b")
    OOMDetector.writeMarker(marker, to: tmp)

    let read = OOMDetector.readAndClearMarker(at: tmp)
    #expect(read == marker)
    // Consume-once: the marker file is gone after reading.
    #expect(!FileManager.default.fileExists(atPath: tmp.path))
    // A second read finds nothing.
    #expect(OOMDetector.readAndClearMarker(at: tmp) == nil)
}

// MARK: - Directory scan + dedup watermark

@Test func oomScanFindsRecentJetsamReport() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("oom-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let reportURL = dir.appendingPathComponent("JetsamEvent-2026-06-12-050000.ips")
    try jetsamReport.write(to: reportURL, atomically: true, encoding: .utf8)

    let findings = OOMDetector.scanDiagnosticReports(
        dir: dir, processName: "darkbloom", since: Date(timeIntervalSince1970: 0))
    #expect(findings.count == 1)
    #expect(findings.first?.reportName == "JetsamEvent-2026-06-12-050000.ips")
    #expect(findings.first?.peakMemoryBytes == UInt64(1_572_864) * 16_384)

    // The `since` watermark excludes older reports → crashloop dedup.
    let future = OOMDetector.scanDiagnosticReports(
        dir: dir, processName: "darkbloom", since: Date(timeIntervalSinceNow: 3600))
    #expect(future.isEmpty)
}

@Test func oomScanIsEmptyForMissingDirectory() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    #expect(OOMDetector.scanDiagnosticReports(
        dir: missing, processName: "darkbloom", since: Date(timeIntervalSince1970: 0)).isEmpty)
}

// MARK: - detectOnLaunch dedup (marker vs crash report)

/// When BOTH a pre-death marker and a real JetsamEvent exist for the same death,
/// detectOnLaunch must emit ONE finding (the authoritative crash report), not two.
@Test func oomDetectOnLaunchPrefersCrashReportOverMarker() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oom-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let markerURL = dir.appendingPathComponent("oom_marker.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    OOMDetector.writeMarker(OOMDetector.Marker(
        pid: 1, epochSeconds: 1, peakMemoryBytes: 1, availableBytesAtEvent: 0), to: markerURL)
    try jetsamReport.write(
        to: dir.appendingPathComponent("JetsamEvent-x.ips"), atomically: true, encoding: .utf8)

    let findings = OOMDetector.detectOnLaunch(
        markerURL: markerURL, diagnosticReportsDirs: [dir],
        processName: "darkbloom", since: Date(timeIntervalSince1970: 0))
    #expect(findings.count == 1)
    #expect(findings.first?.source == .jetsamReport)
    // Marker is consumed either way (no lingering false positive next launch).
    #expect(!FileManager.default.fileExists(atPath: markerURL.path))
}

/// With no crash report, the marker IS surfaced (the only signal we have).
@Test func oomDetectOnLaunchEmitsMarkerWhenNoCrashReport() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oom-dl2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let markerURL = dir.appendingPathComponent("oom_marker.json")
    defer { try? FileManager.default.removeItem(at: dir) }

    OOMDetector.writeMarker(OOMDetector.Marker(
        pid: 1, epochSeconds: 1, peakMemoryBytes: 42, availableBytesAtEvent: 0), to: markerURL)

    let findings = OOMDetector.detectOnLaunch(
        markerURL: markerURL, diagnosticReportsDirs: [dir],
        processName: "darkbloom", since: Date(timeIntervalSince1970: 0))
    #expect(findings.count == 1)
    #expect(findings.first?.source == .memoryPressureMarker)
    #expect(findings.first?.peakMemoryBytes == 42)
}

@Test func oomLastScanWatermarkRoundTrip() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("oom-lastscan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(OOMDetector.loadLastScan(at: tmp) == nil)
    let when = Date(timeIntervalSince1970: 1_780_001_234)
    OOMDetector.saveLastScan(when, at: tmp)
    let read = OOMDetector.loadLastScan(at: tmp)
    #expect(read != nil)
    #expect(abs((read?.timeIntervalSince1970 ?? 0) - 1_780_001_234) < 1.0)
}

// MARK: - Memory-pressure policy

@Test func memoryPressurePolicyEscalates() {
    let normal = MemoryPressurePolicy.response(for: .normal)
    #expect(!normal.clearCache && !normal.writeMarker && normal.severity == nil)

    let warning = MemoryPressurePolicy.response(for: .warning)
    #expect(warning.clearCache && !warning.writeMarker && warning.severity == nil)

    let critical = MemoryPressurePolicy.response(for: .critical)
    #expect(critical.clearCache && critical.writeMarker && critical.severity == .error)
}

@Test func memoryPressureMonitorHandleInvokesInjectedActions() {
    let clears = LockedCounter()
    let markers = LockedBox()
    let emits = LockedBox()
    let monitor = MemoryPressureMonitor(
        clearCache: { clears.bump() },
        writeMarker: { markers.set($0) },
        emit: { level, _ in emits.set(level) })

    monitor.handle(.warning)
    #expect(clears.value == 1)
    #expect(markers.value == nil)          // warning does not write a marker
    #expect(emits.value == nil)            // warning does not emit telemetry (routine)

    monitor.handle(.critical)
    #expect(clears.value == 2)
    #expect(markers.value == .critical)    // critical writes the marker
    #expect(emits.value == .critical)      // critical emits the oom signal

    monitor.handle(.normal)
    #expect(clears.value == 2)             // normal is a no-op
}

// Tiny thread-safe test helpers (handlers may run off the test thread).
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: MemoryPressureLevel?
    func set(_ x: MemoryPressureLevel) { lock.lock(); v = x; lock.unlock() }
    var value: MemoryPressureLevel? { lock.lock(); defer { lock.unlock() }; return v }
}
