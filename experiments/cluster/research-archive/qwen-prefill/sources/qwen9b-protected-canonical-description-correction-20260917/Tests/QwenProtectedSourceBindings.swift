import Foundation

// Reviewed upstream bytes. The eventual executable and package source snapshot
// must also be pinned externally; this table does not attest loaded machine code.
enum QwenProtectedSourceBindings {
    static let values: [String: String] = [
        "allocationProbe": "d024dfc14844926bd8ee14620826cc9b0ae429fd8a46e097d7a42feede85698e",
        "jaccl/mesh.cpp": "9ceeb94a507113be9206255efff1bb09d9d598e44eabed340c0808e26ce0cf22",
        "jaccl/mesh_impl.h": "3ea07df67aae3d0327f111de3b7673c8c76a6c2362682d4b085cd10a8d5847f5",
        "jaccl/rdma.h": "726f94b96febd2ec294269872d6672bcaf0a4fc97ecbef9474bdf97b4e962498",
        "jaccl/ring_impl.h": "1f71b26a8448f6ef46aafdae0d3ff760b72317cd3276a069b7d6b92024eb2a33",
        "jaccl/send_frame.h": "771846ae0406bc2203b37ec9620b3158405433fbe76421e315296670c3c590c7",
        "nativePrelude": "61f28887e6165c6f488071882868216c6e92bb1f1f6f81cec826c7de0349c5bf",
        "protectedScopes": "4338ce5be25d95c7ec68f87ab2fcd51122ceee8058de636463f5891fe4fee107",
        "security/ClusterAuthenticatedRecordChannel.swift": "6d81628e5780612cbedde71b82e5c5e3fd53ef30cc3810ea97e974a788fead9d",
        "security/ClusterAuthenticatedRecordTransport.swift": "6f20e605f1d0116f192907f3966e3aeeb1c234e6491279a1be7a32a2eb0b23ca",
        "security/ClusterRecordByteIO.swift": "d8a823051dd69cc13a1bd6cd6f69363a4a2fccc5cc36dcbd64b262509ce21d19",
        "security/ClusterRecordFraming.swift": "1bed76a6016cc18ef4a35b45c2af305bfe5ce1342c925d9e74bd6bcda55effce",
        "security/ClusterRecordState.swift": "91577a9cf2b9a7d274846e13274764825e3cb1de1459d869955b1d21027b1e61",
        "security/ClusterRecordTransferAccounting.swift": "aab036c9991f35e40f2a7d8a0283c8fc54c73f40b3e36f52a1515f6b5e36339d",
        "security/ClusterRecordTransferExpectation.swift": "151f673993b3391d4fd0ba937c04d2d6531fb23bd248f46a5b608f97ddc96a57",
        "security/ClusterRecordTypes.swift": "723e1e63d9b6f8fc0a38f47b94152fa026fba478d05642494b6aab05f6940366",
    ]
}
