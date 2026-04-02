//! Provider scheduling — time-based availability windows.
//!
//! Users configure when their machine should serve inference requests.
//! Outside scheduled windows, the provider disconnects from the coordinator
//! and shuts down the backend to free GPU memory.
//!
//! Schedule windows support:
//!   - Day-of-week selection (Mon-Sun)
//!   - Start/end times in 24h local time
//!   - Overnight windows (e.g., 22:00-08:00 = serve overnight)
//!   - Multiple windows (e.g., weekday evenings + all weekend)
//!
//! When no schedule is configured or scheduling is disabled, the provider
//! is always available (current default behavior).

use chrono::{Datelike, Local, NaiveTime, Timelike, Weekday};
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// A single availability window.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ScheduleWindow {
    /// Days this window applies to (e.g., ["mon", "tue", "wed"]).
    pub days: Vec<String>,
    /// Start time in HH:MM 24h format.
    pub start: String,
    /// End time in HH:MM 24h format. If end < start, wraps overnight.
    pub end: String,
}

/// Schedule configuration.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ScheduleConfig {
    pub enabled: bool,
    #[serde(default)]
    pub windows: Vec<ScheduleWindow>,
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            windows: Vec::new(),
        }
    }
}

/// Parsed schedule ready for evaluation.
pub struct Schedule {
    windows: Vec<ParsedWindow>,
}

struct ParsedWindow {
    days: Vec<Weekday>,
    start: NaiveTime,
    end: NaiveTime,
    overnight: bool, // true when end < start (e.g., 22:00-08:00)
}

fn parse_day(s: &str) -> Option<Weekday> {
    match s.to_lowercase().as_str() {
        "mon" | "monday" => Some(Weekday::Mon),
        "tue" | "tuesday" => Some(Weekday::Tue),
        "wed" | "wednesday" => Some(Weekday::Wed),
        "thu" | "thursday" => Some(Weekday::Thu),
        "fri" | "friday" => Some(Weekday::Fri),
        "sat" | "saturday" => Some(Weekday::Sat),
        "sun" | "sunday" => Some(Weekday::Sun),
        _ => None,
    }
}

fn parse_time(s: &str) -> Option<NaiveTime> {
    NaiveTime::parse_from_str(s, "%H:%M").ok()
}

impl Schedule {
    /// Parse a ScheduleConfig into a Schedule ready for evaluation.
    pub fn from_config(config: &ScheduleConfig) -> Option<Self> {
        if !config.enabled || config.windows.is_empty() {
            return None;
        }

        let mut windows = Vec::new();
        for w in &config.windows {
            let days: Vec<Weekday> = w.days.iter().filter_map(|d| parse_day(d)).collect();
            if days.is_empty() {
                continue;
            }
            let start = match parse_time(&w.start) {
                Some(t) => t,
                None => continue,
            };
            let end = match parse_time(&w.end) {
                Some(t) => t,
                None => continue,
            };
            let overnight = end <= start;
            windows.push(ParsedWindow {
                days,
                start,
                end,
                overnight,
            });
        }

        if windows.is_empty() {
            return None;
        }

        Some(Self { windows })
    }

    /// Check if the current local time is within any scheduled window.
    pub fn is_active_now(&self) -> bool {
        let now = Local::now();
        let today = now.weekday();
        let time = now.time();

        for w in &self.windows {
            if w.overnight {
                // Overnight window (e.g., 22:00-08:00):
                // Active if: (today is in days AND time >= start)
                //         OR (yesterday is in days AND time < end)
                let yesterday = prev_weekday(today);
                if w.days.contains(&today) && time >= w.start {
                    return true;
                }
                if w.days.contains(&yesterday) && time < w.end {
                    return true;
                }
            } else {
                // Same-day window (e.g., 09:00-17:00):
                if w.days.contains(&today) && time >= w.start && time < w.end {
                    return true;
                }
            }
        }

        false
    }

    /// How long until the current active window ends.
    /// Returns None if not currently active.
    pub fn duration_until_inactive(&self) -> Option<Duration> {
        let now = Local::now();
        let today = now.weekday();
        let time = now.time();

        for w in &self.windows {
            if w.overnight {
                let yesterday = prev_weekday(today);
                if w.days.contains(&today) && time >= w.start {
                    // Window ends tomorrow at w.end
                    let remaining_today = secs_until_midnight(time);
                    let into_tomorrow = time_to_secs(w.end);
                    return Some(Duration::from_secs(remaining_today + into_tomorrow));
                }
                if w.days.contains(&yesterday) && time < w.end {
                    // Window ends today at w.end
                    let diff = time_to_secs(w.end) - time_to_secs(time);
                    return Some(Duration::from_secs(diff));
                }
            } else if w.days.contains(&today) && time >= w.start && time < w.end {
                let diff = time_to_secs(w.end) - time_to_secs(time);
                return Some(Duration::from_secs(diff));
            }
        }

        None
    }

    /// How long until the next window opens.
    /// Returns Duration::ZERO if already active.
    pub fn duration_until_next_active(&self) -> Duration {
        if self.is_active_now() {
            return Duration::ZERO;
        }

        let now = Local::now();
        let today = now.weekday();
        let time = now.time();

        let mut min_wait = u64::MAX;

        // Check each window across the next 7 days
        for w in &self.windows {
            for day_offset in 0u64..7 {
                let check_day = weekday_plus(today, day_offset as usize);
                if !w.days.contains(&check_day) {
                    continue;
                }

                let wait = if day_offset == 0 && time < w.start {
                    // Today, window hasn't started yet
                    time_to_secs(w.start) - time_to_secs(time)
                } else if day_offset > 0 {
                    // Future day
                    let remaining_today = secs_until_midnight(time);
                    let full_days = (day_offset - 1) * 86400;
                    let into_target = time_to_secs(w.start);
                    remaining_today + full_days + into_target
                } else {
                    continue; // Today but window already passed
                };

                if wait < min_wait {
                    min_wait = wait;
                }
            }
        }

        if min_wait == u64::MAX {
            Duration::from_secs(3600) // fallback: check again in 1 hour
        } else {
            Duration::from_secs(min_wait)
        }
    }

    /// Human-readable description of the schedule.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        for w in &self.windows {
            let days: Vec<&str> = w.days.iter().map(|d| weekday_abbrev(d)).collect();
            parts.push(format!("{} {}-{}", days.join(","), w.start, w.end));
        }
        parts.join(" | ")
    }
}

fn prev_weekday(day: Weekday) -> Weekday {
    match day {
        Weekday::Mon => Weekday::Sun,
        Weekday::Tue => Weekday::Mon,
        Weekday::Wed => Weekday::Tue,
        Weekday::Thu => Weekday::Wed,
        Weekday::Fri => Weekday::Thu,
        Weekday::Sat => Weekday::Fri,
        Weekday::Sun => Weekday::Sat,
    }
}

fn weekday_plus(day: Weekday, n: usize) -> Weekday {
    let days = [
        Weekday::Mon,
        Weekday::Tue,
        Weekday::Wed,
        Weekday::Thu,
        Weekday::Fri,
        Weekday::Sat,
        Weekday::Sun,
    ];
    let idx = day.num_days_from_monday() as usize;
    days[(idx + n) % 7]
}

fn weekday_abbrev(day: &Weekday) -> &'static str {
    match day {
        Weekday::Mon => "Mon",
        Weekday::Tue => "Tue",
        Weekday::Wed => "Wed",
        Weekday::Thu => "Thu",
        Weekday::Fri => "Fri",
        Weekday::Sat => "Sat",
        Weekday::Sun => "Sun",
    }
}

fn time_to_secs(t: NaiveTime) -> u64 {
    t.hour() as u64 * 3600 + t.minute() as u64 * 60 + t.second() as u64
}

fn secs_until_midnight(t: NaiveTime) -> u64 {
    86400 - time_to_secs(t)
}

/// Format a Duration as a human-readable string (e.g., "2h 30m").
pub fn format_duration(d: Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else {
        let h = secs / 3600;
        let m = (secs % 3600) / 60;
        if m > 0 {
            format!("{h}h {m}m")
        } else {
            format!("{h}h")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weekday_config(days: Vec<&str>, start: &str, end: &str) -> ScheduleConfig {
        ScheduleConfig {
            enabled: true,
            windows: vec![ScheduleWindow {
                days: days.into_iter().map(String::from).collect(),
                start: start.to_string(),
                end: end.to_string(),
            }],
        }
    }

    #[test]
    fn test_disabled_schedule_returns_none() {
        let config = ScheduleConfig {
            enabled: false,
            windows: vec![],
        };
        assert!(Schedule::from_config(&config).is_none());
    }

    #[test]
    fn test_empty_windows_returns_none() {
        let config = ScheduleConfig {
            enabled: true,
            windows: vec![],
        };
        assert!(Schedule::from_config(&config).is_none());
    }

    #[test]
    fn test_parse_days() {
        assert_eq!(parse_day("mon"), Some(Weekday::Mon));
        assert_eq!(parse_day("Monday"), Some(Weekday::Mon));
        assert_eq!(parse_day("FRI"), Some(Weekday::Fri));
        assert_eq!(parse_day("invalid"), None);
    }

    #[test]
    fn test_all_days_schedule_is_always_active() {
        let config = weekday_config(
            vec!["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            "00:00",
            "23:59",
        );
        let schedule = Schedule::from_config(&config).unwrap();
        assert!(schedule.is_active_now());
    }

    #[test]
    fn test_overnight_window_detection() {
        let config = weekday_config(
            vec!["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            "22:00",
            "08:00",
        );
        let schedule = Schedule::from_config(&config).unwrap();
        // This window is overnight — verify it parsed correctly
        assert!(schedule.windows[0].overnight);
    }

    #[test]
    fn test_same_day_window_detection() {
        let config = weekday_config(vec!["mon", "tue", "wed", "thu", "fri"], "09:00", "17:00");
        let schedule = Schedule::from_config(&config).unwrap();
        assert!(!schedule.windows[0].overnight);
    }

    #[test]
    fn test_duration_until_next_active_when_active() {
        let config = weekday_config(
            vec!["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            "00:00",
            "23:59",
        );
        let schedule = Schedule::from_config(&config).unwrap();
        assert_eq!(schedule.duration_until_next_active(), Duration::ZERO);
    }

    #[test]
    fn test_describe() {
        let config = ScheduleConfig {
            enabled: true,
            windows: vec![
                ScheduleWindow {
                    days: vec!["mon".into(), "tue".into(), "wed".into()],
                    start: "09:00".into(),
                    end: "17:00".into(),
                },
                ScheduleWindow {
                    days: vec!["sat".into(), "sun".into()],
                    start: "00:00".into(),
                    end: "23:59".into(),
                },
            ],
        };
        let schedule = Schedule::from_config(&config).unwrap();
        let desc = schedule.describe();
        assert!(desc.contains("Mon"));
        assert!(desc.contains("09:00"));
        assert!(desc.contains("Sat"));
    }

    #[test]
    fn test_format_duration() {
        assert_eq!(format_duration(Duration::from_secs(30)), "30s");
        assert_eq!(format_duration(Duration::from_secs(90)), "1m");
        assert_eq!(format_duration(Duration::from_secs(3600)), "1h");
        assert_eq!(format_duration(Duration::from_secs(5400)), "1h 30m");
    }

    #[test]
    fn test_prev_weekday() {
        assert_eq!(prev_weekday(Weekday::Mon), Weekday::Sun);
        assert_eq!(prev_weekday(Weekday::Wed), Weekday::Tue);
        assert_eq!(prev_weekday(Weekday::Sun), Weekday::Sat);
    }

    #[test]
    fn test_weekday_plus() {
        assert_eq!(weekday_plus(Weekday::Mon, 0), Weekday::Mon);
        assert_eq!(weekday_plus(Weekday::Mon, 4), Weekday::Fri);
        assert_eq!(weekday_plus(Weekday::Fri, 3), Weekday::Mon);
        assert_eq!(weekday_plus(Weekday::Sun, 1), Weekday::Mon);
    }

    #[test]
    fn test_config_roundtrip() {
        let config = ScheduleConfig {
            enabled: true,
            windows: vec![ScheduleWindow {
                days: vec!["mon".into(), "fri".into()],
                start: "22:00".into(),
                end: "08:00".into(),
            }],
        };

        let toml_str = toml::to_string_pretty(&config).unwrap();
        let parsed: ScheduleConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(config, parsed);
    }
}
