//! The apptokens request with a per-call claim override
//! (design doc §1, §5, §6.2).
//!
//! isideload's public `AppleAccount::get_app_token` always uses the
//! sign-in claim (`GrandSlam.client_info`, fixed at construction),
//! and its header builder (`GrandSlam::base_headers`) is private.
//! This module therefore rebuilds the request exactly as
//! `get_app_token` does — same checksum, same plist body, same
//! `gsService` URL, same GCM token decryption — but with headers
//! built from the caller-supplied `AnisetteClientInfo`, posting
//! through the account's own public `grandslam_client.client`.
//! It uses only isideload's *public* API and fields
//! (`GrandSlam.client`, `GrandSlam.get_url`, `AppleAccount.spd`,
//! `AnisetteDataGenerator::get_anisette_data`, the public
//! `PlistDataExtract` trait and `GrandSlamErrorChecker`); the GCM
//! decryption below is our own implementation of the documented
//! format (`"XYZ"` prefix, 16-byte IV, AAD `"XYZ"`, key = SPD `sk`).
//! The token VALUE never leaves this module: only its length,
//! duration and expiry are returned (design doc §5.1.6).

use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use hmac::{Hmac, Mac};
use isideload::anisette::AnisetteClientInfo;
use isideload::auth::apple_account::AppleAccount;
use isideload::auth::grandslam::GrandSlamErrorChecker;
use isideload::util::plist::PlistDataExtract;
use plist::{Dictionary, Value};
use reqwest::header::{HeaderMap, HeaderValue};
use rootcause::prelude::*;
use sha2::Sha256;

/// Token metadata only — never the token string (design doc §5.1.6).
pub struct TokenMeta {
    pub token_length: usize,
    pub duration: u64,
    pub expiry: u64,
}

/// Headers for one GrandSlam plist request, built from the override
/// claim. This mirrors isideload's `GrandSlam::base_headers`
/// (non-SMS branch) exactly, except `Content-Type`/`Accept` come
/// from the session's `content_type` switch (design doc §9 Q1 —
/// see `claims::parse_content_type`): the default is isideload's
/// `text/x-xml-plist`; the spike can flip it to `text/xml` to test
/// the Apparition finding on this one call without a fork.
fn override_headers(
    claim: &AnisetteClientInfo,
    content_type: &str,
) -> Result<HeaderMap, Report> {
    let mut headers = HeaderMap::new();
    headers.insert(
        "Content-Type",
        HeaderValue::from_str(content_type)?,
    );
    headers.insert("Accept", HeaderValue::from_str(content_type)?);
    headers.insert(
        "X-Mme-Client-Info",
        HeaderValue::from_str(&claim.client_info)?,
    );
    headers.insert(
        "User-Agent",
        HeaderValue::from_str(&claim.user_agent)?,
    );
    headers.insert(
        "X-Xcode-Version",
        HeaderValue::from_static("27.0 (27A5218g)"),
    );
    headers.insert(
        "X-Apple-App-Info",
        HeaderValue::from_static("com.apple.gs.xcode.auth"),
    );
    headers.insert(
        reqwest::header::CONNECTION,
        HeaderValue::from_static("close"),
    );
    Ok(headers)
}

/// Our own AES-256-GCM decryption for the `et` field, in the format
/// isideload documents and the Phase 0 spike harness verified:
/// `et = "XYZ" || 16-byte IV || ciphertext+tag`, AAD `"XYZ"`,
/// key = SPD session key `sk` (32 bytes).
fn decrypt_gcm(data: &[u8], key: &[u8]) -> Result<Vec<u8>, Report> {
    if data.len() < 3 + 16 + 16 {
        bail!(
            "Encrypted token is too short to be valid (only {} bytes)",
            data.len()
        );
    }
    if &data[0..3] != b"XYZ" {
        bail!("Encrypted token is in an unknown format");
    }
    if key.len() != 32 {
        bail!(
            "Session key is not the correct length: {} bytes",
            key.len()
        );
    }
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|e| report!("Failed to create app-token cipher: {e}"))?;
    let nonce = Nonce::try_from(&data[3..19])
        .map_err(|_| report!("App-token nonce is not 16 bytes"))?;
    cipher
        .decrypt(
            &nonce,
            Payload {
                msg: &data[19..],
                aad: b"XYZ",
            },
        )
        .map_err(|e| report!("Failed to decrypt app token: {e}"))
}

/// Fetch the app token for `app` (already normalised to
/// `com.apple.gs.<app>`) using `claim` for this request only.
/// Mirrors `AppleAccount::get_app_token`, including its 429 retry
/// behaviour (`err_429_retries`, default 10; `None` disables retries
/// and lets `error_for_status` report the 429 directly).
pub async fn get_app_token_with_claim(
    account: &mut AppleAccount,
    app: &str,
    claim: &AnisetteClientInfo,
    content_type: &str,
    err_429_retries: Option<u32>,
) -> Result<TokenMeta, Report> {
    let anisette_data = account
        .anisette_generator
        .get_anisette_data(account.grandslam_client.clone())
        .await
        .context("Failed to get anisette data for login")?;

    let spd = account
        .spd
        .as_ref()
        .ok_or_else(|| report!("SPD data not available, cannot get app token"))?;

    let dsid = spd.get_str("adsid").context("Failed to get app token")?;
    let auth_token = spd
        .get_str("GsIdmsToken")
        .context("Failed to get app token")?;
    let session_key = spd.get_data("sk").context("Failed to get app token")?;
    let c = spd.get_data("c").context("Failed to get app token")?;

    // checksum = HMAC-SHA256(sk, "apptokens" || dsid || app)
    let checksum = Hmac::<Sha256>::new_from_slice(session_key)
        .context("Failed to create HMAC for app token checksum")?
        .chain_update(b"apptokens")
        .chain_update(dsid.as_bytes())
        .chain_update(app.as_bytes())
        .finalize()
        .into_bytes()
        .to_vec();

    let gs_service_url = account
        .grandslam_client
        .get_url("gsService")
        .context("Failed to get GrandSlam service URL")?;
    let cpd = anisette_data.get_client_provided_data();

    let mut request = Dictionary::new();
    request.insert(
        "app".to_string(),
        Value::Array(vec![Value::String(app.to_string())]),
    );
    request.insert("c".to_string(), Value::Data(c.to_vec()));
    request.insert("checksum".to_string(), Value::Data(checksum));
    request.insert("cpd".to_string(), Value::Dictionary(cpd));
    request.insert("o".to_string(), Value::String("apptokens".to_string()));
    request.insert("u".to_string(), Value::String(dsid.to_string()));
    request.insert("t".to_string(), Value::String(auth_token.to_string()));

    let mut top = Dictionary::new();
    let mut header = Dictionary::new();
    header.insert(
        "Version".to_string(),
        Value::String("1.0.1".to_string()),
    );
    top.insert("Header".to_string(), Value::Dictionary(header));
    top.insert("Request".to_string(), Value::Dictionary(request));

    let mut xml = Vec::new();
    plist::to_writer_xml(&mut xml, &Value::Dictionary(top))
        .context("Failed to serialise apptokens plist")?;

    let headers = override_headers(claim, content_type)?;

    // POST with the same 429 retry rule as GrandSlam::plist_request.
    let mut remaining = err_429_retries;
    let text: String;
    loop {
        let resp = account
            .grandslam_client
            .client
            .post(&gs_service_url)
            .headers(headers.clone())
            .body(xml.clone())
            .send()
            .await
            .context("Failed to send app token request")?;
        if resp.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            if let Some(n) = remaining {
                if n > 0 {
                    remaining = Some(n - 1);
                    continue;
                }
                bail!("Received 429 Too Many Requests, no retries left");
            }
            // No retry budget configured: fall through and let
            // error_for_status report the 429.
        }
        text = resp
            .error_for_status()
            .context("Received error response from grandslam")?
            .text()
            .await
            .context("Failed to read grandslam response as text")?;
        break;
    }

    let dict: Dictionary = plist::from_bytes(text.as_bytes())
        .context("Failed to parse grandslam response plist")
        .attach_with(|| text.clone())?;
    let response = dict
        .get("Response")
        .and_then(|v| v.as_dictionary())
        .cloned()
        .ok_or_else(|| report!("grandslam response missing 'Response'"))?;
    let response = response
        .check_grandslam_error()
        .context("GrandSlam error during app token request")?;

    let encrypted_token = response
        .get_data("et")
        .context("Failed to get encrypted token")?;
    let decrypted_token = decrypt_gcm(encrypted_token, session_key)
        .context("Failed to decrypt app token")?;
    let token: Dictionary = plist::from_bytes(&decrypted_token)
        .context("Failed to parse decrypted app token plist")?;

    let status = token
        .get_signed_integer("status-code")
        .context("Failed to get status code from app token")?;
    if status != 200 {
        bail!("App token request failed with status code {status}");
    }
    let token_dict = token
        .get_dict("t")
        .context("Failed to get token dictionary from app token")?;
    let app_token = token_dict
        .get_dict(app)
        .context("Failed to get app token string")?;

    Ok(TokenMeta {
        token_length: app_token
            .get_str("token")
            .context("Failed to get app token string")?
            .len(),
        duration: app_token
            .get_signed_integer("duration")
            .context("Failed to get app token duration")? as u64,
        expiry: app_token
            .get_signed_integer("expiry")
            .context("Failed to get app token expiry")? as u64,
    })
}
