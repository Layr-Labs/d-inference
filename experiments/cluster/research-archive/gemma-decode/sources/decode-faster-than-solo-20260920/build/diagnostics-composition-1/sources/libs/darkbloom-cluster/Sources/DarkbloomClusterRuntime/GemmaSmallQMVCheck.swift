import Foundation
import MLX

@_spi(ClusterTesting) public enum GemmaSmallQMVCheck {
    public static func run(arguments: [String]) throws -> Data {
        if arguments == ["--describe"] {
            return try JSONSerialization.data(withJSONObject:[
                "schema":"gemma_small_qmv_description_v1","passed":true,"metadataOnly":true,
                "modes":["--dense","--gathered"],"maximumRows":3,"groupSize":64,
                "denseCaseCount":108,"gatheredCaseCount":288,"gatheredDeviceRefusalControls":12,
                "dtypes":["bfloat16","float32"],"maximumNativeExtraBytes":GemmaSmallQMVResources.reserve,
                "maximumHostBytes":GemmaSmallQMVResources.reserve,
                "actualFreeFloorBytes":10*1024*1024*1024+2*GemmaSmallQMVResources.reserve,
                "hardDeadlineSeconds":300,"runtimeServingEnabled":false,
                "modelExecuted":false,"defaultDispatchChanged":false],options:[.sortedKeys])
        }
        guard arguments == ["--dense"] || arguments == ["--gathered"] else {
            throw ProbeError("Use exactly --describe, --dense, or --gathered")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000_000
        return try MLX.withError { native in
            Memory.cacheLimit = 0; Memory.clearCache(); try native.check()
            let resources = GemmaSmallQMVResources(deadline:deadline)
            func checked() throws { try resources.check(native:{ try native.check() }) }
            do {
                try checked()
                let rows = try autoreleasepool {
                    if arguments == ["--dense"] {
                        return try GemmaSmallDenseQMVCheck.run(resources:resources,check:checked,native:{ try native.check() })
                    }
                    return try GemmaSmallGatherQMVCheck.run(resources:resources,check:checked,native:{ try native.check() })
                }
                try GemmaSmallQMVMeasurement.fence(native:{ try native.check() })
                Memory.clearCache(); try checked()
                let expected = arguments == ["--dense"] ? 108 : 288
                guard rows.count == expected else { throw ProbeError("Small QMV fixture membership differs") }
                let result: [String:Any] = [
                    "schema":"gemma_small_qmv_result_v1","mode":arguments[0],
                    "passed":rows.allSatisfy { ($0["passed"] as? Bool) == true },
                    "caseCount":rows.count,"cases":rows,"warmupCount":1,"measurementCount":3,
                    "gatheredDeviceRefusalControls":arguments == ["--gathered"] ? 12 : 0,
                    "nativeExtraReserveBytes":GemmaSmallQMVResources.reserve,
                    "hostReserveBytes":GemmaSmallQMVResources.reserve,
                    "resourceObservations":resources.observations,"minimumActualFreeBytes":resources.minimumFree,
                    "peakExtraActiveBytes":resources.peakExtraActive,"cacheBytesAfterRelease":Memory.cacheMemory,
                    "acceptance":"exact finite output bytes against named reference; no tolerance",
                    "timing":"fresh graph+eval+checked GPU/CPU fences; guards and CPU comparison excluded",
                    "runtimeServingEnabled":false,"modelExecuted":false,"defaultDispatchChanged":false,
                    "physicalProcessOrLeaseRetirementEstablished":false]
                let bytes = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.withoutEscapingSlashes])
                guard bytes.count <= 1_048_576 else { throw ProbeError("Small QMV result exceeds bound") }
                try checked(); return bytes
            } catch {
                try GemmaSmallQMVMeasurement.fence(native:{ try native.check() })
                Memory.clearCache(); try native.check(); throw error
            }
        }
    }
}
