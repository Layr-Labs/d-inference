import Foundation
import Metal

private func fieldSafe(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: "|")
        .replacingOccurrences(of: "\r", with: "|")
        .replacingOccurrences(of: " ", with: "_")
}

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("fatal: Metal device unavailable\n".utf8))
    exit(1)
}

print("METAL_COUNTER_DEVICE name=\(fieldSafe(device.name))")
let samplingPoints: [(String, MTLCounterSamplingPoint)] = [
    ("stage_boundary", .atStageBoundary),
    ("draw_boundary", .atDrawBoundary),
    ("dispatch_boundary", .atDispatchBoundary),
    ("blit_boundary", .atBlitBoundary),
]
for (name, point) in samplingPoints {
    print(
        "METAL_COUNTER_SAMPLING"
            + " point=\(name)"
            + " supported=\(device.supportsCounterSampling(point))")
}
let sets = device.counterSets ?? []
print("METAL_COUNTER_SET_COUNT=\(sets.count)")
for set in sets {
    let descriptor = MTLCounterSampleBufferDescriptor()
    descriptor.counterSet = set
    descriptor.storageMode = .shared
    descriptor.sampleCount = 2
    let names = set.counters.map(\.name).joined(separator: ",")
    do {
        _ = try device.makeCounterSampleBuffer(descriptor: descriptor)
        print(
            "METAL_COUNTER_SET"
                + " name=\(fieldSafe(set.name))"
                + " counters=\(fieldSafe(names))"
                + " allocation=pass")
    } catch {
        print(
            "METAL_COUNTER_SET"
                + " name=\(fieldSafe(set.name))"
                + " counters=\(fieldSafe(names))"
                + " allocation=fail"
                + " detail=\(fieldSafe(String(describing: error)))")
    }
}
