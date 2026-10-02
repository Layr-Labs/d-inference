//! Swift `String(Double)` spelling used by both Nemotron filters. The typed
//! request bridge has already converted integral JSON inputs to signed Ints.

pub(super) fn swift_float(value: f64) -> String {
    let scientific = format!("{value:e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap();
    let exponent = exponent.parse::<i32>().unwrap();
    if (-4..16).contains(&exponent) {
        if value.fract() == 0.0 {
            format!("{value:.1}")
        } else {
            value.to_string()
        }
    } else {
        format!("{mantissa}e{exponent:+03}")
    }
}
