//! Have I Been Pwned range queries for the user-started breach check. Only the
//! 5-character SHA-1 prefix leaves the device; the core computes the prefix and
//! matches the response locally. The UI gets no general network access.

use nsh_core::prelude::*;
use std::io::Read;
use std::time::Duration;

const ENDPOINT: &str = "https://api.pwnedpasswords.com/range/";
const MAX_RESPONSE: u64 = 4 * 1024 * 1024;

/// Opt-in Have I Been Pwned k-anonymity range lookup (5-hex SHA-1 prefix only).
#[module]
pub struct Breach;

#[module]
impl Breach {
    /// The padded range response for one prefix (five uppercase hex digits).
    pub async fn range(prefix: String) -> Result<String, String> {
        if !valid_prefix(&prefix) {
            return Err("InvalidData".into());
        }
        blocking(move || fetch(&prefix))
            .await
            .map_err(|_| "Network".to_string())?
    }
}

fn valid_prefix(prefix: &str) -> bool {
    prefix.len() == 5
        && prefix
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
}

fn fetch(prefix: &str) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| "Network")?;
    let response = client
        .get(format!("{ENDPOINT}{prefix}"))
        .header("Add-Padding", "true")
        .send()
        .map_err(|_| "Network")?;
    if response.status() != reqwest::StatusCode::OK {
        return Err("Network".into());
    }
    let mut body = String::new();
    response
        .take(MAX_RESPONSE + 1)
        .read_to_string(&mut body)
        .map_err(|_| "Network")?;
    if body.len() as u64 > MAX_RESPONSE {
        return Err("InvalidData".into());
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::valid_prefix;

    #[test]
    fn only_five_uppercase_hex_digits_are_sent() {
        assert!(valid_prefix("21BD1"));
        assert!(valid_prefix("00000"));
        for bad in ["21bd1", "21BD", "21BD12", "21BG1", "", "../x1", "21BD1/"] {
            assert!(!valid_prefix(bad), "{bad}");
        }
    }
}
