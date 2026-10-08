import Foundation
import CoreFoundation
import CryptoKit
struct ProbeError: Error { let description: String; init(_ value:String){description=value} }
enum BoundedProbeInput {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return number as? Int
    }
}
func sha256(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
@main struct ActualStagePlanCheck {
 static func main() throws {
  let configuration = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let namesData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
  let names = try JSONDecoder().decode([String].self,from:namesData)
  guard sha256(configuration)=="c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423" else {throw ProbeError("Actual configuration differs")}
  let plan = try QwenLayerStagePlan(configuration:configuration,ranges:[0..<16,16..<32])
  let mapped = try plan.parameters(canonicalSourceNames:names)
  guard mapped.count==927 && names.count==1291 else {throw ProbeError("Actual canonical text inventory differs")}
  let output:[String:Any] = ["cpuOnly":true,"pipelineExecutionValidated":false,"weightPayloadRead":false,
    "configurationSHA256":sha256(configuration),"sourceNamesSHA256":sha256(namesData),
    "sourceParameters":names.count,"mappedTextParameters":mapped.count,"excludedParameters":names.count-mapped.count,
    "planSHA256":plan.fingerprint,"stages":plan.stages.map { stage in ["stage":stage.index,
      "sourceLayerStart":stage.sourceRange.lowerBound,"sourceLayerEnd":stage.sourceRange.upperBound,
      "mappedParameters":mapped.filter{$0.stage==stage.index}.count,"fingerprint":stage.fingerprint,
      "configurationSHA256":sha256(stage.constructionConfiguration)] as [String:Any]}]
  let data=try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys,.prettyPrinted])
  FileHandle.standardOutput.write(data+Data([10]))
 }
}
