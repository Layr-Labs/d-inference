//! Request-owned UTC Gregorian date; keep in sync with Swift PromptRenderDate.

pub const BODY_FIELD: &str = "_darkbloom_prompt_date";

pub fn valid_date(value: &str) -> bool {
    let b = value.as_bytes();
    if b.len() != 10
        || b[4] != b'-'
        || b[7] != b'-'
        || !b
            .iter()
            .enumerate()
            .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
    {
        return false;
    }
    let year = value[..4].parse::<u32>().unwrap();
    let month = value[5..7].parse::<usize>().unwrap();
    let day = value[8..].parse::<u32>().unwrap();
    if year == 0 || !(1..=12).contains(&month) {
        return false;
    }
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    (1..=days[month - 1]).contains(&day)
}

/// Conservatively reject indirect calls and computed or unreviewed formats,
/// including occurrences in branches that render fixtures may never execute.
pub fn supports_template(source: &str) -> bool {
    let mut rest = source;
    while let Some(index) = rest.find("strftime_now") {
        if index > 0 {
            let previous = rest.as_bytes()[index - 1];
            if !previous.is_ascii() || previous.is_ascii_alphanumeric() || b"_.".contains(&previous)
            {
                return false;
            }
        }
        let suffix = &rest[index + "strftime_now".len()..];
        let Some(suffix) = suffix.trim_start().strip_prefix('(') else {
            return false;
        };
        let suffix = suffix.trim_start();
        let Some(suffix) = suffix
            .strip_prefix("\"%Y-%m-%d\"")
            .or_else(|| suffix.strip_prefix("'%Y-%m-%d'"))
        else {
            return false;
        };
        let Some(suffix) = suffix.trim_start().strip_prefix(')') else {
            return false;
        };
        rest = suffix;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_gregorian_dates() {
        for value in [
            "0001-01-01",
            "2028-02-29",
            "2000-02-29",
            "2026-09-05",
            "9999-12-31",
        ] {
            assert!(valid_date(value), "{value}");
        }
        for value in [
            "0000-01-01",
            "1900-02-29",
            "2026-02-29",
            "2026-04-31",
            "2026-13-01",
            "2026-01-00",
            "2026-1-01",
            "2026-01-01Z",
            "２０２６-01-01",
            " 2026-01-01",
        ] {
            assert!(!valid_date(value), "{value}");
        }
    }

    #[test]
    fn only_direct_literal_date_calls_participate() {
        for source in [
            "static text",
            r#"{{ strftime_now("%Y-%m-%d") }}"#,
            "{{ strftime_now ( '%Y-%m-%d' ) }}",
        ] {
            assert!(supports_template(source), "{source}");
        }
        for source in [
            r#"{{ strftime_now("%H") }}"#,
            "{{ strftime_now(fmt) }}",
            "{% set clock = strftime_now %}",
            r#"{{ x.strftime_now("%Y-%m-%d") }}"#,
            r#"{% if false %}{{ strftime_now("%S") }}{% endif %}"#,
            r#"{{ strftime_now("%Y-%m-%d", ignored=true) }}"#,
        ] {
            assert!(!supports_template(source), "{source}");
        }
    }
}
