use std::time::Duration;

use super::{
    super::PrivyVerifierError,
    support::{JwtFixture, TokenClaims, unix_time},
};

#[tokio::test]
async fn privy_verifier_enforces_all_identity_claims_and_throttles_unknown_keys() {
    let fixture = JwtFixture::start().await;
    let verifier = fixture.verifier();
    let subject = "did:privy:valid-user";
    let token = fixture.valid_token(subject);

    let (first, second, third) = tokio::join!(
        verifier.verify(&token),
        verifier.verify(&token),
        verifier.verify(&token)
    );
    let verified = first.expect("valid Privy token");
    second.expect("concurrent Privy verification");
    third.expect("concurrent Privy verification");
    assert_eq!(verified.subject, subject);
    assert_eq!(
        fixture.request_count(),
        1,
        "concurrent cold-cache verification caused a JWKS fetch stampede"
    );

    let mut wrong_issuer = TokenClaims::valid(subject);
    wrong_issuer.iss = "attacker.invalid".to_owned();
    assert_invalid(&verifier.verify(&fixture.token(wrong_issuer)).await);

    let mut wrong_audience = TokenClaims::valid(subject);
    wrong_audience.aud = "different-app".to_owned();
    assert_invalid(&verifier.verify(&fixture.token(wrong_audience)).await);

    let mut expired = TokenClaims::valid(subject);
    expired.exp = unix_time().saturating_sub(1);
    assert_invalid(&verifier.verify(&fixture.token(expired)).await);

    let mut not_yet_valid = TokenClaims::valid(subject);
    not_yet_valid.nbf = Some(unix_time().saturating_add(60));
    assert_invalid(&verifier.verify(&fixture.token(not_yet_valid)).await);

    let invalid_subject = TokenClaims::valid("external-subject");
    assert_invalid(&verifier.verify(&fixture.token(invalid_subject)).await);

    let unknown_key = fixture.token_with_kid(TokenClaims::valid(subject), "unknown-key");
    assert!(matches!(
        verifier.verify(&unknown_key).await,
        Err(PrivyVerifierError::UnknownKey)
    ));
    assert_eq!(
        fixture.request_count(),
        1,
        "an unknown kid inside the refresh interval triggered another fetch"
    );
}

#[tokio::test]
async fn expired_jwks_is_never_used_when_refresh_fails() {
    let fixture =
        JwtFixture::start_with_timing(Duration::from_millis(20), Duration::from_millis(5)).await;
    let verifier = fixture.verifier();
    let token = fixture.valid_token("did:privy:no-stale-fallback");

    verifier.verify(&token).await.expect("prime JWKS cache");
    fixture.stop_server();
    tokio::time::sleep(Duration::from_millis(30)).await;

    assert!(matches!(
        verifier.verify(&token).await,
        Err(PrivyVerifierError::Http(_) | PrivyVerifierError::FetchTimeout)
    ));
    assert!(
        matches!(
            verifier.verify(&token).await,
            Err(PrivyVerifierError::RefreshThrottled)
        ),
        "a failed refresh was not negatively cached"
    );
}

fn assert_invalid(result: &Result<super::super::VerifiedPrivyClaims, PrivyVerifierError>) {
    assert!(matches!(result, Err(PrivyVerifierError::InvalidToken)));
}
