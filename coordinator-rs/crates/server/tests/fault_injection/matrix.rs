use super::*;

#[test]
fn exports_compiled_fault_instrumentation_registry() {
    darkbloom_coordinator_server::fault::write_instrumentation_registry()
        .expect("write signed instrumentation registry");

    let definitions = FaultPoint::ALL.map(FaultPoint::definition);
    assert_eq!(definitions.len(), 21);
    assert_eq!(
        definitions
            .iter()
            .map(|definition| definition.id)
            .collect::<BTreeSet<_>>()
            .len(),
        definitions.len()
    );
    assert!(
        definitions.iter().all(|definition| {
            !definition.file.is_empty()
                && !definition.symbol.is_empty()
                && !definition.guarantees.is_empty()
        }),
        "compiled registry contains an incomplete production hook"
    );
}
