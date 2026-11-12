import Foundation
import MLX
import MLXLMCommon

enum GemmaSmallGatherQMVCheck {
    static func run(resources: GemmaSmallQMVResources, check: () throws -> Void,
                    native: () throws -> Void) throws -> [[String:Any]] {
        var reports: [[String:Any]] = []
        for dtype in [DType.bfloat16,.float32] {
            for (name,k,n,salt) in [("gate",2816,704,UInt32(17)),("up",2816,704,71),("down",704,2816,139)] {
                try resources.admit(experts:24,k:k,n:n,bits:4,dtype:dtype); try check()
                try autoreleasepool {
                    let matrix = try GemmaSmallQMVFixture.matrix(experts:24,k:k,n:n,bits:4,dtype:dtype,salt:salt,check:check)
                    eval(matrix.weight,matrix.scales,matrix.biases); try native()
                    try GemmaSmallQMVMeasurement.fence(native:native); try check()
                    for layout in GemmaSmallGatherQMV.InputLayout.allCases {
                        for route in GemmaSmallGatherQMVCases.all {
                            for cancellation in [false,true] {
                                let row = try autoreleasepool { () throws -> [String:Any] in
                                try check()
                                    let rows = layout == .tokenRows ? route.tokens : route.tokens*8
                                    var x = GemmaSmallQMVFixture.input(rows:rows,k:k,dtype:dtype,cancellation:cancellation)
                                    if layout == .assignmentRows { x = x.reshaped([route.tokens,8,k]) }
                                    let ids = MLXArray(route.ids,[route.tokens,8])
                                    eval(x,ids); try native(); try GemmaSmallQMVMeasurement.fence(native:native); try check()
                                    var result = try GemmaSmallQMVMeasurement.compare(
                                        label:"gather/\(name)/\(dtype)/\(layout.rawValue)/\(route.name)/cancel-\(cancellation)",
                                        metadata:["kind":"gather","K":k,"N":n,"bits":4,"dtype":"\(dtype)",
                                            "rows":route.tokens,"topK":8,"experts":24,"distinctExperts":route.uniqueExperts,
                                            "inputLayout":layout.rawValue,"route":route.ids,"cancellationInput":cancellation,
                                            "reference":"unchanged-unsorted-gatherQuantizedMM"],check:check,native:native,
                                        reference:{ [GemmaSmallGatherQMV.reference(x,weight:matrix.weight,scales:matrix.scales,
                                            biases:matrix.biases,indices:ids,layout:layout)] },
                                        candidate:{ [try GemmaSmallGatherQMV.project(x,weight:matrix.weight,scales:matrix.scales,
                                            biases:matrix.biases,indices:ids,layout:layout)] })
                                    if name == "down" {
                                        let weights = MLXArray((0..<(route.tokens*8)).map {
                                            Float(1+$0%8)/36
                                        },[route.tokens,8]).asType(dtype)
                                        func weighted(candidate: Bool) throws -> [MLXArray] {
                                            let outputs: MLXArray
                                            if candidate {
                                                outputs = try GemmaSmallGatherQMV.project(x,weight:matrix.weight,scales:matrix.scales,
                                                    biases:matrix.biases,indices:ids,layout:layout)
                                            } else {
                                                outputs = GemmaSmallGatherQMV.reference(x,weight:matrix.weight,scales:matrix.scales,
                                                    biases:matrix.biases,indices:ids,layout:layout)
                                            }
                                            return [weightedExpertSum(outputs,weights)]
                                        }
                                        let a = try GemmaSmallQMVMeasurement.sample(check:check,native:native) { try weighted(candidate:false) }
                                        let b = try GemmaSmallQMVMeasurement.sample(check:check,native:native) { try weighted(candidate:true) }
                                        let exact = a.finite && b.finite && a.bytes == b.bytes
                                        result["weightedOriginalSlotsExact"] = exact
                                        result["weightedReferenceSHA256"] = sha256(a.bytes)
                                        result["weightedCandidateSHA256"] = sha256(b.bytes)
                                        result["passed"] = (result["passed"] as? Bool) == true && exact
                                    }
                                    return result
                                }
                                reports.append(row); try check()
                            }
                        }
                    }
                    // Actual device invalid-route controls: poison, never access
                    // an out-of-range plane, and never return finite acceptance.
                    for bad in [[UInt32(24),1,2,3,4,5,6,7],[UInt32(0),0,2,3,4,5,6,7]] {
                        let x = GemmaSmallQMVFixture.input(rows:1,k:k,dtype:dtype,cancellation:false)
                        let ids = MLXArray(bad,[1,8])
                        let sample = try GemmaSmallQMVMeasurement.sample(check:check,native:native) {
                            [try GemmaSmallGatherQMV.project(x,weight:matrix.weight,scales:matrix.scales,
                                biases:matrix.biases,indices:ids,layout:.tokenRows)]
                        }
                        guard !sample.finite else { throw ProbeError("Malformed expert route yielded finite acceptance") }
                    }
                }
                try GemmaSmallQMVMeasurement.fence(native:native)
                Memory.clearCache(); try check()
            }
        }
        return reports
    }
}
