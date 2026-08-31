import Foundation

public final class WorkerCodeChallengeRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let launchIdentifier: String
    public let connectionGeneration: UInt64
    public let senderPublicKey: Data
    public let ciphertext: Data

    public init?(version: UInt16 = InferenceWorkerContract.version,
                 launchIdentifier: String, connectionGeneration: UInt64,
                 senderPublicKey: Data, ciphertext: Data) {
        guard version == InferenceWorkerContract.version,
              !launchIdentifier.isEmpty, launchIdentifier.utf8.count <= 256,
              connectionGeneration > 0, senderPublicKey.count == 32,
              !ciphertext.isEmpty,
              ciphertext.count <= InferenceWorkerContract.maximumMetadataBytes else { return nil }
        self.version = version
        self.launchIdentifier = launchIdentifier
        self.connectionGeneration = connectionGeneration
        self.senderPublicKey = senderPublicKey
        self.ciphertext = ciphertext
    }

    public required init?(coder: NSCoder) {
        guard let launch = coder.decodeObject(of: NSString.self, forKey: "launch") as? String,
              let key = coder.decodeObject(of: NSData.self, forKey: "key") as? Data,
              let ciphertext = coder.decodeObject(of: NSData.self, forKey: "ciphertext") as? Data,
              let value = WorkerCodeChallengeRequest(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")),
                launchIdentifier: launch,
                connectionGeneration: UInt64(coder.decodeInt64(forKey: "generation")),
                senderPublicKey: key, ciphertext: ciphertext) else { return nil }
        version = value.version
        launchIdentifier = value.launchIdentifier
        connectionGeneration = value.connectionGeneration
        senderPublicKey = value.senderPublicKey
        self.ciphertext = value.ciphertext
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(launchIdentifier as NSString, forKey: "launch")
        coder.encode(Int64(clamping: connectionGeneration), forKey: "generation")
        coder.encode(senderPublicKey as NSData, forKey: "key")
        coder.encode(ciphertext as NSData, forKey: "ciphertext")
    }
}

public final class WorkerCodeChallengeProof: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let version: UInt16
    public let launchIdentifier: String
    public let connectionGeneration: UInt64
    public let nonce: String
    public let signature: String
    public let bindingDigest: String

    public init?(version: UInt16 = InferenceWorkerContract.version,
                 launchIdentifier: String, connectionGeneration: UInt64,
                 nonce: String, signature: String, bindingDigest: String) {
        guard version == InferenceWorkerContract.version,
              !launchIdentifier.isEmpty, launchIdentifier.utf8.count <= 256,
              connectionGeneration > 0,
              let nonceData = Data(base64Encoded: nonce), nonceData.count == 32,
              !signature.isEmpty, signature.utf8.count <= 256,
              bindingDigest.count == 64,
              bindingDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.version = version
        self.launchIdentifier = launchIdentifier
        self.connectionGeneration = connectionGeneration
        self.nonce = nonce
        self.signature = signature
        self.bindingDigest = bindingDigest
    }

    public required init?(coder: NSCoder) {
        guard let launch = coder.decodeObject(of: NSString.self, forKey: "launch") as? String,
              let nonce = coder.decodeObject(of: NSString.self, forKey: "nonce") as? String,
              let signature = coder.decodeObject(of: NSString.self, forKey: "signature") as? String,
              let digest = coder.decodeObject(of: NSString.self, forKey: "digest") as? String,
              let value = WorkerCodeChallengeProof(
                version: UInt16(clamping: coder.decodeInteger(forKey: "version")),
                launchIdentifier: launch,
                connectionGeneration: UInt64(coder.decodeInt64(forKey: "generation")),
                nonce: nonce, signature: signature, bindingDigest: digest) else { return nil }
        version = value.version
        launchIdentifier = value.launchIdentifier
        connectionGeneration = value.connectionGeneration
        self.nonce = value.nonce
        self.signature = value.signature
        bindingDigest = value.bindingDigest
    }

    public func encode(with coder: NSCoder) {
        coder.encode(Int(version), forKey: "version")
        coder.encode(launchIdentifier as NSString, forKey: "launch")
        coder.encode(Int64(clamping: connectionGeneration), forKey: "generation")
        coder.encode(nonce as NSString, forKey: "nonce")
        coder.encode(signature as NSString, forKey: "signature")
        coder.encode(bindingDigest as NSString, forKey: "digest")
    }
}
