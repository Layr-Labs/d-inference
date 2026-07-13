use super::*;

#[test]
fn fault_injected_byte_pipe_overflow_cancels_slow_consumer_once() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let cancellations = Arc::new(AtomicUsize::new(0));
    let observed = cancellations.clone();
    let cancellation = RequestCancellation::new(CancellationToken::new(), move |reason| {
        assert_eq!(reason, CancellationReason::SlowConsumer);
        observed.fetch_add(1, Ordering::AcqRel);
    });
    let (sender, _receiver) = byte_pipe(
        BytePipeLimits {
            maximum_items: 2,
            maximum_bytes: 8,
        },
        cancellation,
        None,
    )
    .expect("byte pipe");
    let guard = arm(FaultPoint::BytePipeOverflow, FaultAction::Fail).expect("arm overflow");
    assert_eq!(sender.try_send(vec![1]), Err(PipeError::ByteOverflow));
    assert_eq!(cancellations.load(Ordering::Acquire), 1);
    assert_eq!(
        sender.stats().close_reason,
        Some(PipeCloseReason::ByteOverflow)
    );
    record_receipt(
        "byte_pipe_overflow_cancels_slow_consumer_once",
        &[&guard],
        &["bounded_backpressure", "exactly_one_disposition"],
    );
}

#[tokio::test(flavor = "current_thread")]
#[allow(clippy::await_holding_lock)]
async fn provider_reader_and_writer_faults_preserve_finite_saturation_semantics() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);

    let (_writer, writer) =
        provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
            .expect("provider writer");
    let writer_fault =
        arm(FaultPoint::ProviderWriterSaturation, FaultAction::Fail).expect("arm writer fault");
    assert!(matches!(
        writer.try_send_data(OutboundFrame::Binary(vec![1])),
        Err(WriterEnqueueError::DataSaturated)
    ));
    assert_eq!(
        writer.headroom().available_items,
        ProviderWriterConfig::default().maximum_items,
        "injected rejection consumed writer capacity"
    );
    record_receipt(
        "provider_writer_saturation_preserves_finite_capacity",
        &[&writer_fault],
        &["bounded_backpressure", "no_failover_after_auth"],
    );
    drop(writer_fault);

    let (events, receiver) = session_event_channel(1).expect("provider reader lane");
    let identity = SessionIdentity {
        provider_id: ProviderId::new([1; 16]),
        provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
        session_epoch: SessionEpoch(1),
    };
    let reader_fault =
        arm(FaultPoint::ProviderReaderSaturation, FaultAction::Fail).expect("arm reader fault");
    assert_eq!(
        events
            .send(
                SessionEvent::V2Binary {
                    identity,
                    frame: BinarySessionFrame {
                        header: BinaryFrameHeader {
                            kind: BinaryFrameKind::ResponseChunk,
                            flags: BinaryFrameFlags::EMPTY,
                            minor: 0,
                            provider_id: identity.provider_id,
                            provider_process_generation: identity.provider_process_generation,
                            session_epoch: identity.session_epoch,
                            request_id: WireRequestId::new([3; 16]),
                            attempt_id: AttemptId::new([4; 16]),
                            reservation_id: WireReservationId::new([5; 16]),
                            lease_id: LeaseId::new([6; 16]),
                            nonce: [7; 24],
                            rolling_digest: [8; 32],
                            sequence: 0,
                            ciphertext_len: 0,
                            cumulative_tokens: 0,
                        },
                        ciphertext: Vec::new(),
                    },
                },
                &CancellationToken::new(),
            )
            .await,
        Err(SessionEventSendError::Full)
    );
    assert!(receiver.is_empty(), "injected reader fault queued an event");
    record_receipt(
        "provider_reader_saturation_preserves_finite_capacity",
        &[&reader_fault],
        &["bounded_backpressure", "quiescence_ownership_fencing"],
    );
}
