//! Foreground acquisition policy, shared with host-side logic tests.
use crate::{Error, Result};

pub const HUMAN_IDLE_MS: u64 = 10_000;
pub const INPUT_TAG: usize = 0x4f504355; // attribution only, not authorization

pub fn engine_input(message_extra: usize, device_extra: usize) -> bool {
    message_extra == INPUT_TAG || device_extra == INPUT_TAG
}

/// Seed once, before this connection can inject input. LASTINPUTINFO uses a
/// wrapping 32-bit uptime; subsequent device events use GetTickCount64 directly.
pub fn initial_quiet_until(now: u64, last_input_tick: u32) -> u64 {
    let age = (now as u32).wrapping_sub(last_input_tick) as u64;
    now + HUMAN_IDLE_MS.saturating_sub(age)
}

pub fn activation_required(foreground: bool, now: u64, quiet_until: u64) -> Result<bool> {
    if foreground {
        return Ok(false);
    }
    if now < quiet_until {
        return Err(Error::new(
            "PERSON_ACTIVE",
            "Someone is using the computer: keyboard or mouse input occurred within the last 10 seconds. Foreground was not changed and no input was sent; do not retry automatically.",
        ));
    }
    Ok(true)
}

pub fn verify_activation(foreground: bool) -> Result<()> {
    if foreground {
        Ok(())
    } else {
        Err(Error::new("ACTIVATION_FAILED", "Windows refused foreground activation. No input was sent; bring the target forward and read state again."))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recent_human_input_refuses_before_any_activation() {
        let until = initial_quiet_until(30_000, 29_000);
        assert_eq!(until, 39_000);
        assert_eq!(
            activation_required(false, 30_000, until).unwrap_err().code,
            "PERSON_ACTIVE"
        );
        assert_eq!(
            activation_required(false, 38_999, until).unwrap_err().code,
            "PERSON_ACTIVE"
        );
        assert_eq!(activation_required(true, 30_000, until), Ok(false));
        // A monitored event extends the same deadline, even between requests.
        assert_eq!(
            activation_required(false, 40_000, 39_500 + HUMAN_IDLE_MS)
                .unwrap_err()
                .code,
            "PERSON_ACTIVE"
        );
    }

    #[test]
    fn idle_attempts_activation_at_ten_seconds() {
        let until = initial_quiet_until(30_000, 20_000);
        assert_eq!(activation_required(false, 30_000, until), Ok(true));
        assert_eq!(activation_required(false, 90_000, until), Ok(true));
        assert_eq!(verify_activation(true), Ok(()));
    }

    #[test]
    fn failed_verification_refuses_input() {
        assert_eq!(activation_required(false, 30_000, 30_000), Ok(true));
        assert_eq!(
            verify_activation(false).unwrap_err().code,
            "ACTIVATION_FAILED"
        );
    }

    #[test]
    fn startup_ticks_wrap_without_losing_recent_input() {
        let now = (1u64 << 32) + 500;
        assert_eq!(initial_quiet_until(now, u32::MAX - 499), now + 9_000);
        assert_eq!(initial_quiet_until(now, u32::MAX - 19_499), now);
    }

    #[test]
    fn synthetic_input_is_exempt_from_all_raw_activity_handling() {
        assert!(engine_input(INPUT_TAG, 0));
        assert!(engine_input(0, INPUT_TAG)); // keyboard or mouse payload
        assert!(engine_input(INPUT_TAG, INPUT_TAG));
        assert!(!engine_input(0, 0)); // includes zero-device touchpads
        assert!(!engine_input(123, 456));
    }
}
