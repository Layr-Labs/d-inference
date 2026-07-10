use crypto_box::{SecretKey, aead::OsRng};
use darkbloom_coordinator_protocol::{
    CryptoError, ProtocolError, V2_BINARY_HEADER_LEN,
    crypto::{V2_FRAME_BINDING_DOMAIN, decrypt_box, open_v2_frame, seal_v2_frame},
    limits::MAX_V2_CIPHERTEXT_LEN,
    v2::{
        AttemptId, BinaryFrameFlags, BinaryFrameHeader, BinaryFrameKind, LeaseId, ProviderId,
        ProviderProcessGenerationId, RequestId, ReservationId, SessionEpoch, decode_binary_frame,
        encode_binary_frame,
    },
};
use proptest::prelude::*;

fn header(ciphertext_len: u32) -> BinaryFrameHeader {
    BinaryFrameHeader {
        kind: BinaryFrameKind::ResponseChunk,
        flags: BinaryFrameFlags::FINAL | BinaryFrameFlags::RETRANSMIT,
        minor: 0x1122,
        provider_id: ProviderId::new([0x10; 16]),
        provider_process_generation: ProviderProcessGenerationId::new([0x20; 16]),
        session_epoch: SessionEpoch(0x0102_0304_0506_0708),
        request_id: RequestId::new([0x30; 16]),
        attempt_id: AttemptId::new([0x40; 16]),
        reservation_id: ReservationId::new([0x50; 16]),
        lease_id: LeaseId::new([0x60; 16]),
        nonce: [0x70; 24],
        rolling_digest: [0x80; 32],
        sequence: 0x1112_1314_1516_1718,
        ciphertext_len,
    }
}

#[test]
fn header_offsets_are_exact_network_order_golden() {
    let encoded = header(0x00ff_0102).encode().expect("encode");
    assert_eq!(encoded.len(), 192);
    assert_eq!(&encoded[0..4], b"DBV2");
    assert_eq!(encoded[4], 2);
    assert_eq!(encoded[5], 3);
    assert_eq!(&encoded[6..8], &192_u16.to_be_bytes());
    assert_eq!(&encoded[8..10], &2_u16.to_be_bytes());
    assert_eq!(&encoded[10..12], &0x1122_u16.to_be_bytes());
    assert_eq!(&encoded[12..28], &[0x10; 16]);
    assert_eq!(&encoded[28..44], &[0x20; 16]);
    assert_eq!(&encoded[44..52], &0x0102_0304_0506_0708_u64.to_be_bytes());
    assert_eq!(&encoded[52..68], &[0x30; 16]);
    assert_eq!(&encoded[68..84], &[0x40; 16]);
    assert_eq!(&encoded[84..100], &[0x50; 16]);
    assert_eq!(&encoded[100..116], &[0x60; 16]);
    assert_eq!(&encoded[116..140], &[0x70; 24]);
    assert_eq!(&encoded[140..172], &[0x80; 32]);
    assert_eq!(&encoded[172..180], &0x1112_1314_1516_1718_u64.to_be_bytes());
    assert_eq!(&encoded[180..184], &0x00ff_0102_u32.to_be_bytes());
    assert_eq!(&encoded[184..192], &[0; 8]);
}

#[test]
fn complete_frame_requires_exact_total_length() {
    let ciphertext = b"ciphertext";
    let header = header(ciphertext.len() as u32);
    let encoded = encode_binary_frame(&header, ciphertext).expect("encode frame");
    let decoded = decode_binary_frame(&encoded).expect("decode frame");
    assert_eq!(decoded.header, header);
    assert_eq!(decoded.ciphertext, ciphertext);

    let mut trailing = encoded.to_vec();
    trailing.push(0);
    assert!(matches!(
        decode_binary_frame(&trailing),
        Err(ProtocolError::FrameLengthMismatch { .. })
    ));
    assert!(matches!(
        decode_binary_frame(&encoded[..encoded.len() - 1]),
        Err(ProtocolError::FrameLengthMismatch { .. })
    ));
}

#[test]
fn authenticated_frame_crypto_rejects_metadata_rebinding_after_raw_box_open() {
    let sender = SecretKey::generate(&mut OsRng);
    let recipient = SecretKey::generate(&mut OsRng);
    let wire = seal_v2_frame(
        &sender.to_bytes(),
        recipient.public_key().as_bytes(),
        header(0),
        b"bound application plaintext",
    )
    .expect("seal bound frame");
    let opened = open_v2_frame(&recipient.to_bytes(), sender.public_key().as_bytes(), &wire)
        .expect("open bound frame");
    assert_eq!(opened.plaintext, b"bound application plaintext");

    // Every mutation remains syntactically valid. Since NaCl Box has no AAD,
    // low-level decryption still succeeds; the authenticated inner/outer
    // equality check is what rejects metadata rebinding.
    for (name, offset) in [
        ("kind", 4),
        ("flags", 5),
        ("minor", 11),
        ("provider_id", 12),
        ("process_generation", 28),
        ("session_epoch", 44),
        ("request_id", 52),
        ("attempt_id", 68),
        ("reservation_id", 84),
        ("lease_id", 100),
        ("rolling_digest", 140),
        ("sequence", 172),
    ] {
        let mut tampered = wire.to_vec();
        tampered[offset] ^= 1;
        let outer = decode_binary_frame(&tampered)
            .unwrap_or_else(|error| panic!("{name} mutation must remain a valid frame: {error}"));
        let raw_plaintext = decrypt_box(
            &recipient.to_bytes(),
            sender.public_key().as_bytes(),
            &outer.header.nonce,
            outer.ciphertext,
        )
        .unwrap_or_else(|error| panic!("{name} mutation still raw-decrypts: {error}"));
        assert!(raw_plaintext.starts_with(V2_FRAME_BINDING_DOMAIN));
        assert!(matches!(
            open_v2_frame(
                &recipient.to_bytes(),
                sender.public_key().as_bytes(),
                &tampered
            ),
            Err(CryptoError::FrameHeaderBindingMismatch)
        ));
    }
}

#[test]
fn fixed_validation_rejects_each_invalid_header_contract() {
    let valid = header(0).encode().expect("valid header");
    for length in 0..V2_BINARY_HEADER_LEN {
        assert!(
            decode_binary_frame(&valid[..length]).is_err(),
            "accepted truncation at {length}"
        );
    }

    for (offset, value) in [(0, b'X'), (7, 0), (9, 0), (184, 1)] {
        let mut malformed = valid;
        malformed[offset] = value;
        assert!(
            decode_binary_frame(&malformed).is_err(),
            "accepted invalid byte at {offset}"
        );
    }

    let mut unknown_kind = valid;
    unknown_kind[4] = 0xff;
    assert!(matches!(
        decode_binary_frame(&unknown_kind),
        Err(ProtocolError::UnknownFrameKind(0xff))
    ));

    let mut unknown_flags = valid;
    unknown_flags[5] = 0x80;
    assert!(matches!(
        decode_binary_frame(&unknown_flags),
        Err(ProtocolError::UnknownFrameFlags(0x80))
    ));
}

#[test]
fn attacker_ciphertext_length_is_rejected_before_payload_access() {
    let mut encoded = header(0).encode().expect("valid header");
    encoded[180..184].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(matches!(
        decode_binary_frame(&encoded),
        Err(ProtocolError::CiphertextTooLarge {
            actual,
            maximum: MAX_V2_CIPHERTEXT_LEN
        }) if actual == u32::MAX as usize
    ));
}

proptest! {
    #[test]
    fn arbitrary_malformed_frames_never_panic_or_allocate_from_wire_length(
        input in prop::collection::vec(any::<u8>(), 0..4096),
    ) {
        let _ = decode_binary_frame(&input);
    }

    #[test]
    fn valid_headers_round_trip(
        minor in any::<u16>(),
        epoch in any::<u64>(),
        sequence in any::<u64>(),
        ciphertext in prop::collection::vec(any::<u8>(), 0..2048),
    ) {
        let mut header = header(ciphertext.len() as u32);
        header.minor = minor;
        header.session_epoch = SessionEpoch(epoch);
        header.sequence = sequence;
        let frame = encode_binary_frame(&header, &ciphertext).expect("bounded frame");
        let decoded = decode_binary_frame(&frame).expect("round trip");
        prop_assert_eq!(decoded.header, header);
        prop_assert_eq!(decoded.ciphertext, ciphertext);
    }

    #[test]
    fn every_property_generated_truncation_is_rejected(length in 0_usize..V2_BINARY_HEADER_LEN) {
        let encoded = header(0).encode().expect("valid header");
        let rejected = matches!(
            decode_binary_frame(&encoded[..length]),
            Err(ProtocolError::TruncatedHeader { .. })
        );
        prop_assert!(rejected);
    }

    #[test]
    fn oversized_wire_lengths_are_rejected_from_header_only(
        length in (MAX_V2_CIPHERTEXT_LEN as u32 + 1)..=u32::MAX,
    ) {
        let mut encoded = header(0).encode().expect("valid header");
        encoded[180..184].copy_from_slice(&length.to_be_bytes());
        let rejected = matches!(
            decode_binary_frame(&encoded),
            Err(ProtocolError::CiphertextTooLarge { .. })
        );
        prop_assert!(rejected);
    }
}
