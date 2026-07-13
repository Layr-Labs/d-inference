use super::error::BillingError;

pub(super) const MICRO_USD_PER_USD: i64 = 1_000_000;
pub(super) const MICRO_USD_PER_CENT: i64 = 10_000;
pub(super) const MIN_STRIPE_DEPOSIT_CENTS: i64 = 50;
pub(super) const MIN_WITHDRAW_MICRO_USD: i64 = MICRO_USD_PER_USD;
pub(super) const INSTANT_FEE_BPS: i64 = 150;
pub(super) const INSTANT_FEE_MIN_MICRO_USD: i64 = 500_000;

pub(super) fn parse_usd(value: &str) -> Result<i64, BillingError> {
    let value = value.trim();
    if value.is_empty() || value.starts_with('-') || value.starts_with('+') {
        return Err(invalid_amount());
    }
    let mut parts = value.split('.');
    let whole = parts.next().unwrap_or_default();
    let fraction = parts.next();
    if parts.next().is_some()
        || whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(invalid_amount());
    }
    let fraction = fraction.unwrap_or_default();
    if fraction.len() > 6 || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid_amount());
    }
    let whole = whole
        .parse::<u64>()
        .map_err(|_| invalid_amount())?
        .checked_mul(MICRO_USD_PER_USD as u64)
        .ok_or_else(invalid_amount)?;
    let mut fractional_micro = 0_u64;
    for byte in fraction.bytes() {
        fractional_micro = fractional_micro
            .checked_mul(10)
            .and_then(|value| value.checked_add(u64::from(byte - b'0')))
            .ok_or_else(invalid_amount)?;
    }
    for _ in fraction.len()..6 {
        fractional_micro = fractional_micro
            .checked_mul(10)
            .ok_or_else(invalid_amount)?;
    }
    let total = whole
        .checked_add(fractional_micro)
        .ok_or_else(invalid_amount)?;
    i64::try_from(total).map_err(|_| invalid_amount())
}

pub(super) fn deposit_cents(micro_usd: i64) -> Result<i64, BillingError> {
    if micro_usd <= 0 || micro_usd % MICRO_USD_PER_CENT != 0 {
        return Err(BillingError::bad_request(
            "Stripe deposits must use exact cent precision",
        ));
    }
    let cents = micro_usd / MICRO_USD_PER_CENT;
    if cents < MIN_STRIPE_DEPOSIT_CENTS {
        return Err(BillingError::bad_request(
            "amount_usd must be at least $0.50",
        ));
    }
    Ok(cents)
}

pub(super) fn withdrawal_amounts(
    gross: i64,
    instant: bool,
) -> Result<(i64, i64, i64), BillingError> {
    if gross < MIN_WITHDRAW_MICRO_USD {
        return Err(BillingError::bad_request(
            "minimum Stripe withdrawal is $1.00",
        ));
    }
    let method_fee = if instant {
        let proportional = i128::from(gross)
            .checked_mul(i128::from(INSTANT_FEE_BPS))
            .ok_or_else(invalid_amount)?
            / 10_000;
        let proportional = i64::try_from(proportional).map_err(|_| invalid_amount())?;
        proportional.max(INSTANT_FEE_MIN_MICRO_USD)
    } else {
        0
    };
    let before_rounding = gross
        .checked_sub(method_fee)
        .filter(|value| *value > 0)
        .ok_or_else(invalid_amount)?;
    let cents = before_rounding / MICRO_USD_PER_CENT;
    if cents <= 0 {
        return Err(BillingError::bad_request(
            "withdrawal amount rounds to less than one cent",
        ));
    }
    let transferred_micro_usd = cents
        .checked_mul(MICRO_USD_PER_CENT)
        .ok_or_else(invalid_amount)?;
    let total_fee = gross
        .checked_sub(transferred_micro_usd)
        .ok_or_else(invalid_amount)?;
    Ok((total_fee, transferred_micro_usd, cents))
}

pub(super) fn format_usd(micro_usd: i64) -> String {
    let sign = if micro_usd < 0 { "-" } else { "" };
    let magnitude = i128::from(micro_usd).abs();
    format!(
        "{sign}{}.{:06}",
        magnitude / i128::from(MICRO_USD_PER_USD),
        magnitude % i128::from(MICRO_USD_PER_USD)
    )
}

fn invalid_amount() -> BillingError {
    BillingError::bad_request(
        "amount_usd must be a positive decimal with at most six fractional digits",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimal_conversion_is_exact_and_overflow_safe() {
        assert_eq!(parse_usd("10").expect("ten"), 10_000_000);
        assert_eq!(parse_usd("0.000001").expect("micro"), 1);
        assert_eq!(parse_usd("1.20").expect("fraction"), 1_200_000);
        assert_eq!(
            parse_usd("9223372036854.775807").expect("maximum i64"),
            i64::MAX
        );
        assert!(parse_usd("1.0000001").is_err());
        assert!(parse_usd("9223372036854.775808").is_err());
        assert!(parse_usd("NaN").is_err());
    }

    #[test]
    fn payout_rounding_is_charged_as_fee_not_untracked_dust() {
        assert_eq!(
            withdrawal_amounts(1_000_001, false).expect("standard"),
            (1, 1_000_000, 100)
        );
        assert_eq!(
            withdrawal_amounts(10_000_000, true).expect("instant"),
            (500_000, 9_500_000, 950)
        );
    }
}
