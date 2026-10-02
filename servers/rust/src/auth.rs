use axum::{
    extract::FromRequestParts,
    http::{header::AUTHORIZATION, request::Parts},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, KeyInit, Mac};
use serde::{Deserialize, Serialize};
use serde_json::Number;
use sha2::Sha256;
use std::borrow::Cow;

use crate::{ApiError, AppState, json_object, now_ms};

#[derive(Clone, Serialize)]
pub struct Viewer {
    pub id: i64,
    pub name: String,
}

impl FromRequestParts<AppState> for Viewer {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|header| header.to_str().ok())
            .and_then(|header| header.strip_prefix("Bearer "))
            .ok_or_else(ApiError::unauthorized)?;
        verify(token, &state.secret, now_ms()).ok_or_else(ApiError::unauthorized)
    }
}

#[derive(Deserialize)]
struct Header<'a> {
    #[serde(borrow)]
    alg: Cow<'a, str>,
}

#[derive(Deserialize)]
struct Claims<'a> {
    sub: Number,
    name: String,
    #[serde(borrow)]
    iss: Cow<'a, str>,
    exp: Number,
}

fn safe_integer(value: &Number, minimum: u64) -> Option<u64> {
    const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
    if let Some(integer) = value.as_u64() {
        return (minimum..=MAX_SAFE_INTEGER)
            .contains(&integer)
            .then_some(integer);
    }
    let number = value.as_f64()?;
    (number >= minimum as f64 && number <= MAX_SAFE_INTEGER as f64 && number.fract() == 0.0)
        .then_some(number as u64)
}

pub fn verify(token: &str, secret: &[u8], now: u64) -> Option<Viewer> {
    let mut segments = token.split('.');
    let header = segments.next()?;
    let payload = segments.next()?;
    let signature = segments.next()?;
    if segments.next().is_some() || header.is_empty() || payload.is_empty() || signature.is_empty()
    {
        return None;
    }

    // This engine rejects padding, non-URL characters, and nonzero unused trailing bits.
    let header_bytes = URL_SAFE_NO_PAD.decode(header).ok()?;
    let payload_bytes = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let mut signature_bytes = [0_u8; 32];
    if URL_SAFE_NO_PAD
        .decode_slice(signature, &mut signature_bytes)
        .ok()?
        != 32
    {
        return None;
    }
    let header_value: Header = json_object(&header_bytes)?;
    if header_value.alg != "HS256" {
        return None;
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).ok()?;
    mac.update(header.as_bytes());
    mac.update(b".");
    mac.update(payload.as_bytes());
    mac.verify_slice(&signature_bytes).ok()?;

    let claims: Claims = json_object(&payload_bytes)?;
    let id = safe_integer(&claims.sub, 1)?;
    let exp = safe_integer(&claims.exp, 0)?;
    if claims.iss != "gbb" || exp * 1_000 <= now {
        return None;
    }
    Some(Viewer {
        id: id as i64,
        name: claims.name,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &[u8] = b"auth-test-secret";

    fn signed(header: &str, payload: &str) -> String {
        let header = URL_SAFE_NO_PAD.encode(header);
        let payload = URL_SAFE_NO_PAD.encode(payload);
        sign_segments(&header, &payload)
    }

    fn sign_segments(header: &str, payload: &str) -> String {
        let input = format!("{header}.{payload}");
        let mut mac = Hmac::<Sha256>::new_from_slice(SECRET).unwrap();
        mac.update(input.as_bytes());
        format!(
            "{input}.{}",
            URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
        )
    }

    #[test]
    fn accepts_integral_float_claims_and_preserves_viewer() {
        let token = signed(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":1.0,"name":"User 1","iss":"gbb","exp":2.0}"#,
        );
        let viewer = verify(&token, SECRET, 1_999).unwrap();
        assert_eq!(viewer.id, 1);
        assert_eq!(viewer.name, "User 1");
        assert!(verify(&token, SECRET, 2_000).is_none());
    }

    #[test]
    fn preserves_safe_integer_boundary_in_float_notation() {
        for payload in [
            r#"{"sub":9007199254740991.0,"name":"x","iss":"gbb","exp":9007199254740991.0}"#,
            r#"{"sub":9.007199254740991e15,"name":"x","iss":"gbb","exp":9.007199254740991e15}"#,
        ] {
            let token = signed(r#"{"alg":"HS256"}"#, payload);
            let expiry_ms = 9_007_199_254_740_991_000;
            assert_eq!(
                verify(&token, SECRET, expiry_ms - 1).unwrap().id,
                9_007_199_254_740_991,
            );
            assert!(verify(&token, SECRET, expiry_ms).is_none());
        }
    }

    #[test]
    fn enforces_claim_types_and_safe_integer_ranges() {
        for payload in [
            r#"{"sub":0,"name":"x","iss":"gbb","exp":2}"#,
            r#"{"sub":1.5,"name":"x","iss":"gbb","exp":2}"#,
            r#"{"sub":9007199254740992,"name":"x","iss":"gbb","exp":2}"#,
            r#"{"sub":"1","name":"x","iss":"gbb","exp":2}"#,
            r#"{"sub":1,"name":null,"iss":"gbb","exp":2}"#,
            r#"{"sub":1,"name":"x","iss":"other","exp":2}"#,
            r#"{"sub":1,"name":"x","iss":"gbb","exp":-1}"#,
            r#"{"sub":1,"name":"x","iss":"gbb","exp":2.5}"#,
            r#"{"sub":1,"name":"x","iss":"gbb","exp":9007199254740992}"#,
            r#"{"sub":1,"name":"x","iss":"gbb"}"#,
            r#"[1,"x","gbb",2]"#,
        ] {
            let token = signed(r#"{"alg":"HS256"}"#, payload);
            assert!(verify(&token, SECRET, 0).is_none(), "{payload}");
        }
        let token = signed(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":9007199254740991,"name":"","iss":"gbb","exp":9007199254740991}"#,
        );
        assert_eq!(verify(&token, SECRET, 0).unwrap().id, 9_007_199_254_740_991);
        let zero_exp = signed(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":1,"name":"x","iss":"gbb","exp":0}"#,
        );
        assert!(verify(&zero_exp, SECRET, 0).is_none());
    }

    #[test]
    fn rejects_invalid_headers_signatures_and_segment_counts() {
        let payload = r#"{"sub":1,"name":"x","iss":"gbb","exp":2}"#;
        for header in [r#"{"alg":"none"}"#, r#"["HS256"]"#, "null", "{}"] {
            let token = signed(header, payload);
            assert!(verify(&token, SECRET, 0).is_none());
        }
        let token = signed(r#"{"alg":"HS256"}"#, payload);
        assert!(verify(&token, b"wrong-secret", 0).is_none());
        for invalid in ["", ".a.b", "a..b", "a.b.", "a.b.c.d"] {
            assert!(verify(invalid, SECRET, 0).is_none());
        }
        assert!(verify(&format!("{token}.extra"), SECRET, 0).is_none());
    }

    #[test]
    fn rejects_padding_and_noncanonical_trailing_bits() {
        let token = signed(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":1,"name":"x","iss":"gbb","exp":2}"#,
        );
        assert!(verify(&format!("{token}="), SECRET, 0).is_none());
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut altered = token.into_bytes();
        let last = altered.last_mut().unwrap();
        let index = alphabet.iter().position(|byte| byte == last).unwrap();
        *last = alphabet[index | 1];
        let altered = String::from_utf8(altered).unwrap();
        assert!(verify(&altered, SECRET, 0).is_none());
        let header = format!("{}=", URL_SAFE_NO_PAD.encode(r#"{"alg":"HS256"}"#));
        let token = sign_segments(
            &header,
            &URL_SAFE_NO_PAD.encode(r#"{"sub":1,"name":"x","iss":"gbb","exp":2}"#),
        );
        assert!(verify(&token, SECRET, 0).is_none());
    }
}
