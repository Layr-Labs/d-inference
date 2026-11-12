#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import CryptoKit
import Darwin

enum NativeHardwareError: Error { case binding, io, deadline, incomplete }

struct NativeHardwareInput: Codable, Sendable {
    private struct RequestPacket: Decodable {
        let schema: String, requestID: UUID, modelID: String, artifactSHA256: String
        let profileID: String, promptFileSHA256: String, prefillSchedule: String
        let promptTokenIDs: [Int], stopTokenIDs: [Int]
        let chunkSize: Int, outputCount: Int, stageCut: Int
        let mtpEnabled: Bool
    }
    let schema: String
    let requestFile: String
    let referenceFile: String
    let inputBindingSHA256: String
    let requestSHA256: String
    let referenceSHA256: String
    let tlsConfigurationSHA256: String
    let nativeSHA256: String
    let cliSHA256: String
    let descriptorSHA256: String
    let capabilitySHA256: String
    let resourcePolicySHA256: String
    let planSHA256: String
    let configurationSHA256: String
    let nativePeerIDs: [String]
    let receiptDirectory: String

    static let requestPin = "1645b9ddc580915dd8cbbafe245f82f773da1ceccc440766b4cebf247db19a12"
    static let referencePin = "8a808a8c2a065719442b2eb1a951b5f09dc03cfdb3250403e2a79b0a51d4ae4b"
    static let inputPin = "eeff23029fb833f9e6e7d466903038bb103ae3c4bb45981bc366987221324c07"
    static let publicID = UUID(uuidString:"f6a06d14-9138-4a19-aece-39207e1c874e")!
    static let tokens = [814,20139,1204,264,16097,21208,772,26731,948,310,2919,264,3777,4757,13,58737,279,22980,11,279,6463,1881,8785,7099,16665,321,8785,19101,11,321,799,4145]
    static let expected = [1654,421]

    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func isHash(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    static func canonical(_ path:String)->Bool {
        path.hasPrefix("/") && URL(fileURLWithPath:path).resolvingSymlinksInPath().path==path
    }
    static func read(_ path:String, maximum:Int)->Data? {
        guard canonical(path) else{return nil}
        let fd=Darwin.open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{return nil};defer{Darwin.close(fd)}
        var before=stat(),after=stat()
        guard fstat(fd,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,before.st_size>=0,before.st_size<=maximum else{return nil}
        var bytes=[UInt8](repeating:0,count:Int(before.st_size)+1),offset=0
        while offset<bytes.count {
            let n=bytes.withUnsafeMutableBytes { buffer in Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset) }
            if n<0 && errno==EINTR {continue};if n<0{return nil};if n==0{break};offset += n
        }
        guard offset==Int(before.st_size),fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size else{return nil}
        return Data(bytes.prefix(offset))
    }
    static func load(path:String,pin:String)throws->(NativeHardwareInput,String) {
        guard let data=read(path,maximum:16*1024),isHash(pin),digest(data)==pin else{throw NativeHardwareError.binding}
        let x=try JSONDecoder().decode(Self.self,from:data)
        let expectedKeys:Set<String>=["schema","requestFile","referenceFile","inputBindingSHA256","requestSHA256","referenceSHA256","tlsConfigurationSHA256","nativeSHA256","cliSHA256","descriptorSHA256","capabilitySHA256","resourcePolicySHA256","planSHA256","configurationSHA256","nativePeerIDs","receiptDirectory"]
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys)==expectedKeys,
              x.schema=="native_shared_hardware_leader_v1",x.inputBindingSHA256==inputPin,x.requestSHA256==requestPin,x.referenceSHA256==referencePin,
              [x.tlsConfigurationSHA256,x.nativeSHA256,x.cliSHA256,x.descriptorSHA256,x.capabilitySHA256,x.resourcePolicySHA256,x.planSHA256,x.configurationSHA256].allSatisfy(isHash),
              ProcessInfo.processInfo.environment["DARKBLOOM_PRIVATE_CLUSTER_TLS_SHA256"]==x.tlsConfigurationSHA256,
              x.nativePeerIDs.count==2,Set(x.nativePeerIDs).count==2,
              x.nativePeerIDs.allSatisfy({!$0.isEmpty && $0.utf8.count<=128}),canonical(x.receiptDirectory),
              let request=read(x.requestFile,maximum:16*1024),digest(request)==requestPin,
              let reference=read(x.referenceFile,maximum:128*1024),digest(reference)==referencePin else{throw NativeHardwareError.binding}
        // Bind the private direct injection to the actual original packet. This
        // is not an HTTP ingress claim; the exact public UUID and prompt become
        // the single CBv2 request whose real native UUID the lease exposes.
        let packet=try JSONDecoder().decode(RequestPacket.self,from:request)
        guard packet.schema=="qwen9b_protected_shared_input_v1",packet.requestID==publicID,
              packet.modelID=="registered_qwen35_9b",packet.profileID=="registered_qwen35_9b_greedy_generation_v1",
              packet.artifactSHA256=="127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
              packet.promptFileSHA256=="752bdb476caf6a98fe2a1a7a7e691a9b2522036a28c711b9c78cae98c32f7e9b",
              packet.promptTokenIDs==tokens,packet.stopTokenIDs.isEmpty,
              packet.chunkSize==16,packet.outputCount==2,packet.stageCut==16,
              packet.prefillSchedule=="serial_v1",!packet.mtpEnabled else{throw NativeHardwareError.binding}
        var directoryStat=stat()
        guard lstat(x.receiptDirectory,&directoryStat)==0,(directoryStat.st_mode & S_IFMT)==S_IFDIR,
              (directoryStat.st_mode & 0o777)==0o700 else{throw NativeHardwareError.binding}
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:x.receiptDirectory,isDirectory:&isDirectory),isDirectory.boolValue else{throw NativeHardwareError.binding}
        return (x,pin)
    }
    func publish(_ name:String,_ value:[String:Any])throws {
        guard ["reserved.json","leader-result.json"].contains(name) else{throw NativeHardwareError.binding}
        var data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);data.append(10)
        guard data.count<=16*1024,Self.canonical(receiptDirectory) else{throw NativeHardwareError.binding}
        let fd=Darwin.open(receiptDirectory+"/"+name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw NativeHardwareError.io};defer{Darwin.close(fd)}
        try data.withUnsafeBytes { b in
            var offset=0
            while offset<b.count {
                let n=Darwin.write(fd,b.baseAddress!.advanced(by:offset),b.count-offset)
                if n<0 && errno==EINTR{continue};guard n>0 else{throw NativeHardwareError.io};offset += n
            }
        }
        guard fsync(fd)==0 else{throw NativeHardwareError.io}
    }
}
#endif
