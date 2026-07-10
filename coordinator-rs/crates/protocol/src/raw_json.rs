use serde::Deserialize;
use serde_json::value::RawValue;

#[derive(Deserialize)]
struct RegistrationEnvelope<'a> {
    #[serde(borrow)]
    attestation: Option<&'a RawValue>,
}

/// Returns the exact JSON byte slice carried in a registration's signed
/// `attestation` field.
///
/// The returned slice borrows from `wire`; it is never deserialized and
/// reserialized before signature verification.
pub fn registration_attestation(wire: &str) -> Result<Option<&str>, serde_json::Error> {
    let envelope: RegistrationEnvelope<'_> = serde_json::from_str(wire)?;
    Ok(envelope.attestation.map(RawValue::get))
}

#[cfg(test)]
mod tests {
    use super::registration_attestation;

    #[test]
    fn preserves_signed_object_bytes_exactly() {
        let wire = r#"{"type":"register","attestation": { "z":1,"a":[true, false] }}"#;
        assert_eq!(
            registration_attestation(wire).expect("valid JSON"),
            Some(r#"{ "z":1,"a":[true, false] }"#)
        );
    }
}
