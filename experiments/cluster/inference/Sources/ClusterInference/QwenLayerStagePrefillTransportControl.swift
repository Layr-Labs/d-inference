import Foundation

extension QwenLayerStagePrefillTransport {
    /// Packet preparation/readiness is pre-clock; the driver takes its start
    /// timestamp BEFORE this call, then creates its fresh context after return.
    func sendStart(_ packet: QwenLayerStagePrefillStartWirePacket,
        onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
        check: () throws -> Void) throws {
        try operation {
            try state.requireStart(rank: 0)
            _ = try QwenLayerStagePrefillStartWirePacket.decode(packet.encoded(), expectedAgreement: agreement)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginStartSend); try checked()
            try io.sendBytes(packet.encoded(), maximumBytes: QwenLayerStagePrefillStartWirePacket.maximumEncodedBytes,
                to: 1, check: checked)
            try state.completeStart(packet)
            try onPhase(.startSendCompleted); try checked()
        }
    }

    /// The receiver may construct fresh native request state only after this
    /// strictly validated start returns. No state is created by transport.
    func receiveStart(onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
                      check: () throws -> Void) throws -> QwenLayerStagePrefillStartWirePacket {
        try operation {
            try state.requireStart(rank: 1)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginStartReceive); try checked()
            let data = try io.receiveBytes(maximumBytes: QwenLayerStagePrefillStartWirePacket.maximumEncodedBytes,
                from: 0, check: checked)
            let packet = try QwenLayerStagePrefillStartWirePacket.decode(data, expectedAgreement: agreement)
            try state.completeStart(packet)
            try onPhase(.startValidated); try checked()
            return packet
        }
    }

    /// The actual final receipt was validated and encoded before final consumed
    /// ACK. Send only that saved CPU packet after every boundary has completed.
    func sendFirstToken(onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
                        check: () throws -> Void) throws -> QwenLayerStagePrefillFirstTokenWirePacket {
        try operation {
            let packet = try state.tokenForSend()
            func checked() throws { try self.checked(check) }
            try onPhase(.beginTokenSend); try checked()
            try io.sendBytes(packet.encoded(), maximumBytes: QwenLayerStagePrefillFirstTokenWirePacket.maximumEncodedBytes,
                to: 0, check: checked)
            try state.completeToken(packet)
            try onPhase(.tokenSendCompleted); try checked()
            return packet
        }
    }

    /// Return means the exact final consumed ACK and selected target token have
    /// both been validated. The driver's stop timestamp follows this return.
    func receiveFirstToken(onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
                           check: () throws -> Void) throws -> QwenLayerStagePrefillFirstTokenWirePacket {
        try operation {
            let final = try state.requireTokenTransfer(rank: 0)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginTokenReceive); try checked()
            let data = try io.receiveBytes(maximumBytes: QwenLayerStagePrefillFirstTokenWirePacket.maximumEncodedBytes,
                from: 1, check: checked)
            let packet = try QwenLayerStagePrefillFirstTokenWirePacket.decode(data,
                expectedAgreement: agreement, finalBoundary: final)
            try state.completeToken(packet)
            try onPhase(.tokenValidated); try checked()
            return packet
        }
    }

    /// Semantic post-stop event only: the driver MUST record stop first. This
    /// send and all subsequent observations/retirement are separate work.
    func sendPostStopRelease(onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
                             check: () throws -> Void) throws {
        try operation {
            let token = try state.requirePostStop(rank: 0)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginPostStopSend); try checked()
            try io.sendACK(QwenLayerStagePrefillPostStopAcknowledgement.values(token: token), to: 1, check: checked)
            try state.completePostStop()
            try onPhase(.postStopSendCompleted); try checked()
        }
    }

    /// No final snapshot/full-logit copy/teardown may start on rank one until
    /// this exact post-stop release has completed and passed validation.
    func receivePostStopRelease(onPhase: (QwenLayerStagePrefillControlPhase) throws -> Void,
                                check: () throws -> Void) throws {
        try operation {
            let token = try state.requirePostStop(rank: 1)
            func checked() throws { try self.checked(check) }
            try onPhase(.beginPostStopReceive); try checked()
            let values = try io.receiveACK(from: 0, check: checked)
            try QwenLayerStagePrefillPostStopAcknowledgement.validate(values, token: token)
            try state.completePostStop()
            try onPhase(.postStopValidated); try checked()
        }
    }
}
