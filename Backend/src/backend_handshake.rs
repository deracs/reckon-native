use serde::{Deserialize, Deserializer};
use std::fmt;

/// Secrets can be inspected safely; raw values are exposed only at HTTP boundaries.
#[derive(Clone)]
pub(crate) struct BackendSecret(String);
impl BackendSecret {
    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}
impl fmt::Debug for BackendSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}
impl<'de> Deserialize<'de> for BackendSecret {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value.is_empty() || value.len() > 4096 || !value.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(serde::de::Error::custom("Backend credentials were invalid"));
        }
        Ok(Self(value))
    }
}

/// Credentials arrive over the app-owned stdin pipe, never arguments or environment.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BackendHandshake {
    pub(crate) app_token: BackendSecret,
    pub(crate) user_token: BackendSecret,
    pub(crate) api_token: BackendSecret,
    #[serde(rename = "akahuBaseURL", default = "default_akahu_base_url")]
    pub(crate) akahu_base_url: String,
}
fn default_akahu_base_url() -> String {
    "https://api.akahu.io/v1".to_string()
}
impl BackendHandshake {
    pub(crate) fn parse_handshake(raw: &[u8]) -> Result<Self, ()> {
        let handshake: Self = serde_json::from_slice(raw).map_err(|_| ())?;
        let base = handshake.akahu_base_url.trim_end_matches('/');
        if base == "https://api.akahu.io/v1" && handshake.akahu_base_url.len() <= base.len() + 1 {
            return Ok(handshake);
        }
        for host in ["127.0.0.1", "localhost"] {
            if let Some(port) = base
                .strip_prefix(&format!("http://{host}:"))
                .and_then(|s| s.strip_suffix("/v1"))
                && !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit())
                && port.parse::<u16>().is_ok()
                && handshake.akahu_base_url.len() <= base.len() + 1
            {
                return Ok(handshake);
            }
        }
        Err(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handshake_preserves_fixture_url_acronym_and_redacts_secrets() {
        let handshake = BackendHandshake::parse_handshake(br#"{"appToken":"fixture-app","userToken":"fixture-user","apiToken":"fixture-api","akahuBaseURL":"http://127.0.0.1:4321/v1"}"#).unwrap();
        assert_eq!(handshake.akahu_base_url, "http://127.0.0.1:4321/v1");
        assert_eq!(format!("{:?}", handshake.api_token), "<redacted>");
        for base in [
            "https://attacker.invalid/v1",
            "http://127.0.0.1:4321/v1//",
            "https://api.akahu.io/v1?capture=true",
        ] {
            let raw = serde_json::json!({"appToken":"fixture","userToken":"fixture","apiToken":"fixture","akahuBaseURL":base}).to_string();
            assert!(BackendHandshake::parse_handshake(raw.as_bytes()).is_err());
        }
    }
}
