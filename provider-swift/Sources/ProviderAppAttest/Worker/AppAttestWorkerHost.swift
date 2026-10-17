import CryptoKit
import Darwin
import Foundation
import Sodium

/// Internal executable entry, deliberately not a signing service. No Apple or
/// credential access occurs until the signed parent and its endpoint are bound.
public enum AppAttestWorkerHost {
    public static let argument = "--app-attest-worker-v1"

    public static func run() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw AppAttestWorkerError.unauthenticatedPeer }
        let identity = try WorkerCodeIdentity.current()
        let bootstrap: WorkerBootstrap = try {
            let pipe = WorkerDescriptor(3)
            try WorkerDescriptor.configure(pipe.fd)
            return try WorkerFraming.read(WorkerBootstrap.self, from: pipe, deadline: WorkerDeadline(seconds: 10), limit: 4092)
        }()
        guard bootstrap.version == WorkerBootstrap.version, bootstrap.secret.count == 32,
              bootstrap.parentAuditToken.count == MemoryLayout<audit_token_t>.size,
              !bootstrap.scope.isEmpty, bootstrap.scope.utf8.count <= 2048,
              WorkerRequestValidation.canonical32(bootstrap.endpointPublicKey) else { throw AppAttestWorkerError.invalidMessage }
        let deadline = WorkerDeadline(seconds: 10)
        let socket = try WorkerListener.connect(path: bootstrap.socketPath, deadline: deadline)
        let parent = try WorkerAuditIdentity.peer(socket)
        try identity.authenticate(parent, expectedPID: getppid(), expectedAudit: bootstrap.parentAuditToken)
        let parentExit = DispatchSource.makeProcessSource(identifier: parent.pid, eventMask: .exit, queue: .global(qos: .utility))
        parentExit.setEventHandler { _exit(0) }
        parentExit.resume()
        defer { parentExit.cancel() }
        func send(_ body: WorkerFrame.Body, sequence: UInt64 = 0, deadline: WorkerDeadline) throws {
            try WorkerFraming.send(WorkerFrame(generation: bootstrap.generation, sequence: sequence, body: body), to: socket, deadline: deadline)
        }
        try send(.hello(secret: bootstrap.secret), deadline: deadline)
        let nonce = "darkbloom.app-attest.worker-custody.v1:\(bootstrap.generation.uuidString):\(randomBytes().base64EncodedString())"
        let sodium = Sodium()
        guard let key = sodium.box.keyPair(), let publicKey = Data(base64Encoded: bootstrap.endpointPublicKey),
              let encrypted: Bytes = sodium.box.seal(message: Array(nonce.utf8), recipientPublicKey: Array(publicKey), senderSecretKey: key.secretKey) else {
            throw AppAttestWorkerError.invalidMessage
        }
        let challenge = ShadowEncryptedChallenge(ephemeralPublicKey: Data(key.publicKey).base64EncodedString(), ciphertext: Data(encrypted).base64EncodedString())
        try send(.custodyChallenge(challenge), deadline: deadline)
        let answer = try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: deadline)
        var order = WorkerExchangeOrder(generation: bootstrap.generation)
        try order.require(answer)
        guard case .custodyAnswer(let clear) = answer.body, clear == nonce else { throw AppAttestWorkerError.unauthenticatedPeer }
        try identity.authenticate(parent, expectedPID: getppid(), expectedAudit: bootstrap.parentAuditToken, fullMeasurement: false)
        let credentialLease = try WorkerCredentialLease(scope: bootstrap.scope)
        defer { withExtendedLifetime(credentialLease) {} }
        let callbacks = QualificationAssertionCallbacks(qualificationAllowed: bootstrap.qualificationFaultsAllowed)
        let client = AppAttestShadowClient(scope: bootstrap.scope,
            service: AppleAppAttestService(callbacks: callbacks, operationTimeout: 25))
        try send(.authenticated, deadline: deadline)
        var account: String?
        var environment: String?
        while true {
            // Idle time is bounded as well. A new prepare can launch another
            // worker with the same persisted credential after this one exits.
            let frame = try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: WorkerDeadline(seconds: 20 * 60))
            _ = try order.next()
            try order.require(frame)
            try identity.authenticate(parent, expectedPID: getppid(), expectedAudit: bootstrap.parentAuditToken, fullMeasurement: false)
            if case .armAssertionCallbackDiscard = frame.body {
                guard bootstrap.qualificationFaultsAllowed, account != nil, frame.sequence < UInt64.max,
                      await client.appleOperationHeldSince() == nil else { throw AppAttestWorkerError.invalidMessage }
                let generation = bootstrap.generation
                let assertionSequence = frame.sequence + 1
                try callbacks.armNextAssertion { phase in
                    do {
                        try WorkerFraming.send(WorkerFrame(generation: generation, sequence: assertionSequence,
                            body: .assertionQualificationEvent(phase)), to: socket, deadline: WorkerDeadline(seconds: 1))
                    } catch {
                        // Evidence delivery failure aborts IPC, never manufactures
                        // a proof or releases the deliberately held Apple gate.
                        socket.shutdown()
                    }
                }
                try send(.assertionCallbackDiscardArmed, sequence: frame.sequence, deadline: WorkerDeadline(seconds: 5))
                continue
            }
            guard case .exchange(let request, let status) = frame.body else { throw AppAttestWorkerError.invalidMessage }
            guard !callbacks.requiresNextAssertion || request.action == "assert" else { throw AppAttestWorkerError.invalidMessage }
            try WorkerRequestValidation.validate(request, status: status)
            guard request.encryptedChallenge == nil,
                  status.binaryHash == identity.binaryHash,
                  account == nil || account == request.accountScope,
                  environment == nil || environment == request.environment else { throw AppAttestWorkerError.invalidMessage }
            if account == nil {
                guard request.action == "prepare" else { throw AppAttestWorkerError.staleExchange }
                account = request.accountScope; environment = request.environment
            }
            let payload = await client.respond(to: request, publicKey: bootstrap.endpointPublicKey, status: status)
            let outstanding = await client.appleOperationHeldSince() != nil
            let reply = AppAttestWorkerReply(payload: payload, localStatus: await client.currentLocalStatus(),
                                            runtimeDiagnostics: request.action == "prepare" && !outstanding
                                                ? AppAttestWorkerRuntimeDiagnostics.capture() : nil,
                                            operationOutstanding: outstanding)
            try identity.authenticate(parent, expectedPID: getppid(), expectedAudit: bootstrap.parentAuditToken, fullMeasurement: false)
            try send(.reply(reply), sequence: frame.sequence, deadline: WorkerDeadline(seconds: 5))
            // The supervisor reaps an outstanding operation before replacement.
            // Stay alive long enough for it to authenticate this reply; the gate
            // still forbids another native operation if an extra frame arrives.
        }
    }

    static func randomBytes() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
