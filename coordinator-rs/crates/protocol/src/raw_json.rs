use serde::Deserialize;
use serde_json::value::RawValue;

#[derive(Deserialize)]
struct RegistrationEnvelope<'a> {
    #[serde(rename = "type")]
    message_type: &'a str,
    #[serde(borrow)]
    attestation: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct SignedAttestationEnvelope<'a> {
    #[serde(borrow)]
    attestation: Option<&'a RawValue>,
}

/// Exact signed JSON values borrowed from a provider registration frame.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RegistrationSignedBytes<'a> {
    /// The complete `attestation` field value, including its signature.
    pub attestation: Option<&'a [u8]>,
    /// The nested status value covered by the registration signature.
    pub status: Option<&'a [u8]>,
}

/// Returns the exact JSON byte slice carried in a registration's signed
/// `attestation` field.
///
/// The returned slice borrows from `wire`; it is never deserialized and
/// reserialized before signature verification.
pub fn registration_attestation(wire: &str) -> Result<Option<&str>, serde_json::Error> {
    let envelope: RegistrationEnvelope<'_> = serde_json::from_str(wire)?;
    Ok((envelope.message_type == "register")
        .then_some(envelope.attestation)
        .flatten()
        .map(RawValue::get))
}

/// Extracts signed registration values before the frame is typed.
///
/// Both returned slices borrow the original wire bytes. Callers can therefore
/// verify signatures without introducing a parse/reserialize byte change.
pub fn registration_signed_bytes(
    wire: &[u8],
) -> Result<RegistrationSignedBytes<'_>, serde_json::Error> {
    let envelope: RegistrationEnvelope<'_> = serde_json::from_slice(wire)?;
    if envelope.message_type != "register" {
        return Ok(RegistrationSignedBytes::default());
    }

    let Some(attestation) = envelope.attestation else {
        return Ok(RegistrationSignedBytes::default());
    };
    let status = serde_json::from_str::<SignedAttestationEnvelope<'_>>(attestation.get())
        .ok()
        .and_then(|signed| signed.attestation)
        .map(|value| value.get().as_bytes());
    Ok(RegistrationSignedBytes {
        attestation: Some(attestation.get().as_bytes()),
        status,
    })
}

#[cfg(test)]
mod tests {
    use super::{registration_attestation, registration_signed_bytes};

    #[test]
    fn preserves_signed_object_bytes_exactly() {
        let wire = r#"{"type":"register","attestation": { "z":1,"a":[true, false] }}"#;
        assert_eq!(
            registration_attestation(wire).expect("valid JSON"),
            Some(r#"{ "z":1,"a":[true, false] }"#)
        );
    }

    #[test]
    fn extracts_outer_and_nested_signed_bytes() {
        let wire = br#"{"type":"register","attestation": { "signature":"s", "attestation": { "z":1, "a":false } }}"#;
        let raw = registration_signed_bytes(wire).expect("valid registration");
        assert_eq!(
            raw.attestation,
            Some(&br#"{ "signature":"s", "attestation": { "z":1, "a":false } }"#[..])
        );
        assert_eq!(raw.status, Some(&br#"{ "z":1, "a":false }"#[..]));
    }

    #[test]
    fn ignores_attestation_on_other_message_types() {
        let raw = registration_signed_bytes(br#"{"type":"heartbeat","attestation":{"x":1}}"#)
            .expect("valid message");
        assert_eq!(raw, Default::default());
    }
}
