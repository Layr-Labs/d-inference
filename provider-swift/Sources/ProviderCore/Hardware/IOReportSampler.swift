import Foundation

// Sudoless energy sampling via Apple's private `IOReport` framework.
//
// IOReport exposes cumulative hardware energy counters in the "Energy Model"
// channel group. We open ONE persistent subscription, then on each call diff
// the current cumulative sample against the previous one — the delta is the
// energy (mJ/µJ/nJ) consumed by each subsystem in between. No sudo, no
// entitlement; this is the same source `powermetrics` reads.
//
// On macOS 13–26 the symbols live in the top-level dylib `/usr/lib/libIOReport.dylib`
// (the old IOReport.framework path no longer resolves via dlopen on macOS 26).
// If the library or any symbol is missing, the sampler degrades to `unavailable`
// and the caller falls back to the static wall-power estimate.

// MARK: - Private IOReport C signatures (resolved at runtime via dlsym)

private typealias FnCopyChannels  = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
private typealias FnCreateSub     = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
private typealias FnCreateSamples = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias FnDelta         = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias FnChanStr       = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias FnSimpleInt     = @convention(c) (CFDictionary, Int32) -> Int64

public actor IOReportSampler {

    public private(set) var available = false

    private var handle: UnsafeMutableRawPointer?
    private var subscription: UnsafeMutableRawPointer?
    private var sampleChannels: CFMutableDictionary?
    private var prevSample: CFDictionary?
    private var prevTime: Date?

    private var fnSamples: FnCreateSamples?
    private var fnDelta: FnDelta?
    private var fnGroup: FnChanStr?
    private var fnName: FnChanStr?
    private var fnUnit: FnChanStr?
    private var fnValue: FnSimpleInt?

    public init() {
        let candidates = [
            "/usr/lib/libIOReport.dylib",
            "libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
        ]
        var h: UnsafeMutableRawPointer?
        for path in candidates { if let opened = dlopen(path, RTLD_NOW) { h = opened; break } }
        guard let handle = h else { return }
        self.handle = handle

        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copy = sym("IOReportCopyChannelsInGroup", FnCopyChannels.self),
            let createSub = sym("IOReportCreateSubscription", FnCreateSub.self),
            let samples = sym("IOReportCreateSamples", FnCreateSamples.self),
            let delta = sym("IOReportCreateSamplesDelta", FnDelta.self),
            let group = sym("IOReportChannelGetGroup", FnChanStr.self),
            let name = sym("IOReportChannelGetChannelName", FnChanStr.self),
            let unit = sym("IOReportChannelGetUnitLabel", FnChanStr.self),
            let value = sym("IOReportSimpleGetIntegerValue", FnSimpleInt.self)
        else { return }

        guard
            let channels = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
            let chanMut = CFDictionaryCreateMutableCopy(nil, 0, channels)
        else { return }

        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chanMut, &subbed, 0, nil) else { return }

        self.subscription = sub
        self.sampleChannels = subbed?.takeRetainedValue() ?? chanMut
        self.fnSamples = samples
        self.fnDelta = delta
        self.fnGroup = group
        self.fnName = name
        self.fnUnit = unit
        self.fnValue = value

        // Prime the first sample so the next call yields a valid delta.
        if let chans = sampleChannels, let first = samples(sub, chans, nil)?.takeRetainedValue() {
            prevSample = first
            prevTime = Date()
            available = true
        }
    }

    /// Energy consumed since the previous call, split by subsystem. Returns nil
    /// on the first (priming) call or when measurement is unavailable.
    public func sample() -> EnergySample? {
        guard available,
              let sub = subscription, let chans = sampleChannels,
              let samples = fnSamples, let delta = fnDelta,
              let prev = prevSample, let prevTime,
              let cur = samples(sub, chans, nil)?.takeRetainedValue()
        else { return nil }

        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        prevSample = cur
        self.prevTime = now
        guard elapsed > 0, let d = delta(prev, cur, nil)?.takeRetainedValue() else { return nil }

        let byName = energyByChannel(d)
        let cpu = rollup(byName, exact: "CPU Energy", clusters: ["ECPU", "PCPU", "EACC_CPU", "PACC0_CPU", "PACC1_CPU", "MCPU0", "MCPU1"])
        let gpu = rollup(byName, exact: "GPU Energy", clusters: ["GPU"])
        let ane = rollup(byName, exact: "ANE", clusters: ["ANE0"])
        let dram = rollup(byName, exact: "DRAM", clusters: ["DRAM0"])
        return EnergySample(seconds: elapsed, cpuJoules: cpu, gpuJoules: gpu, aneJoules: ane, dramJoules: dram)
    }

    /// Sum joules per top-level channel name within the Energy Model group.
    private func energyByChannel(_ delta: CFDictionary) -> [String: Double] {
        guard let fnGroup, let fnName, let fnUnit, let fnValue else { return [:] }
        let channelsKey = "IOReportChannels" as CFString
        guard let arrPtr = CFDictionaryGetValue(delta, Unmanaged.passUnretained(channelsKey).toOpaque()) else { return [:] }
        let channels = Unmanaged<CFArray>.fromOpaque(arrPtr).takeUnretainedValue()
        let n = CFArrayGetCount(channels)
        var byName: [String: Double] = [:]
        for i in 0..<n {
            guard let p = CFArrayGetValueAtIndex(channels, i) else { continue }
            let ch = Unmanaged<CFDictionary>.fromOpaque(p).takeUnretainedValue()
            let grp = (fnGroup(ch)?.takeUnretainedValue()) as String?
            guard grp == "Energy Model" else { continue }
            let name = (fnName(ch)?.takeUnretainedValue()) as String? ?? ""
            let unit = (fnUnit(ch)?.takeUnretainedValue()) as String? ?? ""
            let raw = fnValue(ch, 0)
            byName[name, default: 0] += toJoules(raw, unit: unit)
        }
        return byName
    }
}

// MARK: - Free helpers

private func toJoules(_ value: Int64, unit: String) -> Double {
    let v = Double(value)
    switch unit.lowercased() {
    case "mj":       return v / 1_000.0
    case "uj", "µj": return v / 1_000_000.0
    case "nj":       return v / 1_000_000_000.0
    case "j":        return v
    default:         return v / 1_000.0   // assume mJ when unlabeled
    }
}

// IOReport reports the same energy at nested levels (per-DVFS-state *DTL*,
// per-core PACC0_CPU3, cluster PACC0_CPU, rollup "CPU Energy"). Summing
// everything triple-counts — read only the top rollup. `exact` is the single
// rollup channel; `clusters` is the cluster-sum fallback for chips lacking it
// (channel names differ M1–M4 vs M5).
private func rollup(_ byName: [String: Double], exact: String, clusters: [String]) -> Double {
    if let v = byName[exact], v > 0 { return v }
    var sum = 0.0
    for (name, v) in byName {
        let u = name.uppercased()
        if u.contains("DTL") || u.contains("SRAM") { continue }
        if u.range(of: "_CPU[0-9]", options: .regularExpression) != nil { continue }
        if clusters.contains(where: { u == $0 }) { sum += v }
    }
    return sum
}
