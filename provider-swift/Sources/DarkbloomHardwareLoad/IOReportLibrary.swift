import Darwin
import Foundation

/// IOReport channel payload shapes (IOKit `IOReportTypes.h`).
enum IOReportFormat: Int32 {
    case invalid = 0
    case simple = 1
    case state = 2
    case histogram = 3
    case simpleArray = 4
}

/// Every use of private API in this module lives in this file.
///
/// Bound with `dlopen`/`dlsym` rather than linking `libIOReport.tbd`: the binary
/// carries no load command for the private library, so a macOS release that
/// drops or renames a symbol makes `shared` nil (callers report "unavailable")
/// instead of the process failing to launch.
final class IOReportLibrary: @unchecked Sendable {
    static let shared: IOReportLibrary? = IOReportLibrary()
    private static var channelsKey: CFString { "IOReportChannels" as CFString }

    private typealias CopyChannelsInGroupFn = @convention(c) (
        CFString?, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannelsFn = @convention(c) (
        CFMutableDictionary, CFDictionary, UnsafeRawPointer?
    ) -> Void
    private typealias CreateSubscriptionFn = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64, UnsafeRawPointer?
    ) -> OpaquePointer?
    private typealias CreateSamplesFn = @convention(c) (
        OpaquePointer, CFMutableDictionary, UnsafeRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaFn = @convention(c) (
        CFDictionary, CFDictionary, UnsafeRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelInt32Fn = @convention(c) (CFDictionary) -> Int32
    private typealias SimpleValueFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannelsInGroupFn: CopyChannelsInGroupFn
    private let mergeChannelsFn: MergeChannelsFn
    private let createSubscriptionFn: CreateSubscriptionFn
    private let createSamplesFn: CreateSamplesFn
    private let createSamplesDeltaFn: CreateSamplesDeltaFn
    private let groupFn: ChannelStringFn
    private let subgroupFn: ChannelStringFn
    private let nameFn: ChannelStringFn
    private let unitLabelFn: ChannelStringFn
    private let formatFn: ChannelInt32Fn
    private let simpleValueFn: SimpleValueFn
    private let stateCountFn: ChannelInt32Fn
    private let stateNameFn: StateNameFn
    private let stateResidencyFn: StateResidencyFn

    private init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else {
            return nil
        }
        func bind<T>(_ symbol: String, as _: T.Type) -> T? {
            dlsym(handle, symbol).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyInGroup = bind("IOReportCopyChannelsInGroup", as: CopyChannelsInGroupFn.self),
            let merge = bind("IOReportMergeChannels", as: MergeChannelsFn.self),
            let subscribe = bind("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let samples = bind("IOReportCreateSamples", as: CreateSamplesFn.self),
            let delta = bind("IOReportCreateSamplesDelta", as: CreateSamplesDeltaFn.self),
            let group = bind("IOReportChannelGetGroup", as: ChannelStringFn.self),
            let subgroup = bind("IOReportChannelGetSubGroup", as: ChannelStringFn.self),
            let name = bind("IOReportChannelGetChannelName", as: ChannelStringFn.self),
            let unit = bind("IOReportChannelGetUnitLabel", as: ChannelStringFn.self),
            let format = bind("IOReportChannelGetFormat", as: ChannelInt32Fn.self),
            let simple = bind("IOReportSimpleGetIntegerValue", as: SimpleValueFn.self),
            let stateCount = bind("IOReportStateGetCount", as: ChannelInt32Fn.self),
            let stateName = bind("IOReportStateGetNameForIndex", as: StateNameFn.self),
            let stateResidency = bind("IOReportStateGetResidency", as: StateResidencyFn.self)
        else {
            dlclose(handle)
            return nil
        }
        copyChannelsInGroupFn = copyInGroup
        mergeChannelsFn = merge
        createSubscriptionFn = subscribe
        createSamplesFn = samples
        createSamplesDeltaFn = delta
        groupFn = group
        subgroupFn = subgroup
        nameFn = name
        unitLabelFn = unit
        formatFn = format
        simpleValueFn = simple
        stateCountFn = stateCount
        stateNameFn = stateName
        stateResidencyFn = stateResidency
    }

    // MARK: Channel selection

    /// The channels of `group`/`subgroup` that `include` accepts; nil when none survive.
    func channels(
        group: String, subgroup: String? = nil, include: (IOReportChannel) -> Bool
    ) -> CFMutableDictionary? {
        guard
            let all = copyChannelsInGroupFn(group as CFString, subgroup.map { $0 as CFString }, 0, 0, 0)?
                .takeRetainedValue()
        else { return nil }
        let kept = NSMutableArray()
        forEachChannel(in: all) { if include($0) { kept.add($0.dict) } }
        guard kept.count > 0, let result = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all)
        else { return nil }
        CFDictionarySetValue(
            result, Unmanaged.passUnretained(Self.channelsKey).toOpaque(),
            Unmanaged.passUnretained(kept as CFArray).toOpaque())
        return result
    }

    /// Merges `source` into `destination` in place.
    func merge(_ destination: CFMutableDictionary, _ source: CFDictionary) {
        mergeChannelsFn(destination, source, nil)
    }

    fileprivate func forEachChannel(in channels: CFDictionary, _ body: (IOReportChannel) -> Void) {
        guard
            let array = CFDictionaryGetValue(
                channels, Unmanaged.passUnretained(Self.channelsKey).toOpaque())
                .map({ unsafeBitCast($0, to: CFArray.self) })
        else { return }
        for index in 0..<CFArrayGetCount(array) {
            body(
                IOReportChannel(
                    dict: unsafeBitCast(CFArrayGetValueAtIndex(array, index), to: CFDictionary.self),
                    library: self))
        }
    }

    // MARK: Subscription plumbing

    fileprivate func createSubscription(
        _ desired: CFMutableDictionary
    ) -> (OpaquePointer, CFMutableDictionary)? {
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscriptionFn(nil, desired, &subscribed, 0, nil) else {
            subscribed?.release()
            return nil
        }
        // Samples must be created against the subscribed-channel dictionary.
        return (subscription, subscribed?.takeRetainedValue() ?? desired)
    }

    fileprivate func createSamples(
        _ subscription: OpaquePointer, _ channels: CFMutableDictionary
    ) -> CFDictionary? {
        createSamplesFn(subscription, channels, nil)?.takeRetainedValue()
    }

    fileprivate func createDelta(_ previous: CFDictionary, _ current: CFDictionary) -> CFDictionary? {
        createSamplesDeltaFn(previous, current, nil)?.takeRetainedValue()
    }

    // MARK: Channel accessors

    private func string(_ function: ChannelStringFn, _ dict: CFDictionary) -> String {
        function(dict).map { $0.takeUnretainedValue() as String } ?? ""
    }

    fileprivate func group(_ dict: CFDictionary) -> String { string(groupFn, dict) }
    fileprivate func subgroup(_ dict: CFDictionary) -> String { string(subgroupFn, dict) }
    fileprivate func name(_ dict: CFDictionary) -> String { string(nameFn, dict) }
    fileprivate func unit(_ dict: CFDictionary) -> String {
        string(unitLabelFn, dict).trimmingCharacters(in: .whitespaces)
    }
    fileprivate func format(_ dict: CFDictionary) -> IOReportFormat {
        IOReportFormat(rawValue: formatFn(dict)) ?? .invalid
    }
    fileprivate func simpleValue(_ dict: CFDictionary) -> Int64 { simpleValueFn(dict, 0) }
    fileprivate func states(_ dict: CFDictionary) -> [IOReportState] {
        (0..<max(0, Int(stateCountFn(dict)))).map { index in
            IOReportState(
                name: stateNameFn(dict, Int32(index)).map { $0.takeUnretainedValue() as String } ?? "",
                residency: stateResidencyFn(dict, Int32(index)))
        }
    }
}

struct IOReportState: Equatable {
    let name: String
    let residency: Int64
}

/// One channel of a channel list or a sample delta. Values are meaningful only on a delta.
struct IOReportChannel {
    fileprivate let dict: CFDictionary
    fileprivate let library: IOReportLibrary

    var group: String { library.group(dict) }
    var subgroup: String { library.subgroup(dict) }
    var name: String { library.name(dict) }
    var unit: String { library.unit(dict) }

    /// Reading an integer from a non-Simple channel returns garbage, so the format is checked first.
    var simpleValue: Int64? { library.format(dict) == .simple ? library.simpleValue(dict) : nil }

    var states: [IOReportState] { library.format(dict) == .state ? library.states(dict) : [] }
}

/// A live subscription that turns successive snapshots into deltas. Not thread-safe.
final class IOReportSubscription {
    private let library: IOReportLibrary
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, at: UInt64)?

    init?(library: IOReportLibrary, channels desired: CFMutableDictionary) {
        guard let (subscription, subscribed) = library.createSubscription(desired) else { return nil }
        self.library = library
        self.subscription = subscription
        self.channels = subscribed
    }

    deinit { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release() }

    /// Snapshots the counters and visits each channel's change since the
    /// previous call. Returns the window length, or nil on the first call
    /// (which only sets the baseline) and on sampling failure.
    func nextDelta(_ body: (IOReportChannel) -> Void) -> Double? {
        guard let sample = library.createSamples(subscription, channels) else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { previous = (sample, now) }
        guard let previous, now > previous.at,
            let delta = library.createDelta(previous.sample, sample)
        else { return nil }
        library.forEachChannel(in: delta, body)
        return Double(now - previous.at) / 1e9
    }
}
