//! Client-info claim presets (design doc §3 and §5.3) and the
//! Content-Type switch (design doc §9 Q1).
//!
//! Exact strings — also documented in `AppleRefreshBridge.h`.
//! `server` is not a constant: it is whatever the anisette server
//! returns from `GET {server}/v3/client_info`, fetched live at
//! `session_new`.

use isideload::anisette::AnisetteClientInfo;
use serde_json::Value;

/// Default anisette server (design doc §5.2 example + §9 Q10).
pub const DEFAULT_SERVER_URL: &str = "https://mac-ani.jkcoxson.com";

/// Apparition variant (a) — design doc §3 / §5.3.
pub const APPARITION_CLIENT_INFO: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
pub const APPARITION_USER_AGENT: &str = "akd/1.0 CFNetwork/808.1.4";

/// SideInstaller variant (b) — design doc §3 / §5.3.
pub const SIDEINSTALLER_CLIENT_INFO: &str =
    "<MacBookPro16,1> <Mac OS X;10.15.7;19H2> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
pub const SIDEINSTALLER_USER_AGENT: &str = "akd/1.0 CFNetwork/1121.1.2 Darwin/19.7.0";

/// isideload's hardcoded Content-Type (GrandSlam::base_headers).
pub const TEXT_XML_PLIST: &str = "text/x-xml-plist";
/// The Apparition value (see Q1 below).
pub const TEXT_XML: &str = "text/xml";

/// A parsed sign-in / apptokens claim.
/// `custom == None` means preset `server`: use the anisette server's
/// own client_info verbatim. Any other preset resolves to a fixed
/// `AnisetteClientInfo` used as a `set_client_info_override`.
#[derive(Clone, Debug)]
pub struct ClaimSpec {
    pub preset: String,
    pub custom: Option<AnisetteClientInfo>,
}

fn preset_info(preset: &str) -> Option<AnisetteClientInfo> {
    match preset {
        "apparition" => Some(AnisetteClientInfo {
            client_info: APPARITION_CLIENT_INFO.to_string(),
            user_agent: APPARITION_USER_AGENT.to_string(),
        }),
        "sideinstaller" => Some(AnisetteClientInfo {
            client_info: SIDEINSTALLER_CLIENT_INFO.to_string(),
            user_agent: SIDEINSTALLER_USER_AGENT.to_string(),
        }),
        _ => None,
    }
}

/// Header-injection guard for caller-supplied claim strings
/// (design doc §3, `custom` preset): non-empty, no NUL/CR/LF.
pub fn valid_header_value(s: &str) -> bool {
    !s.is_empty() && !s.contains('\0') && !s.contains('\r') && !s.contains('\n')
}

/// Parse a claim object of the shape
/// `{"preset": "server"|"apparition"|"sideinstaller"|"custom",
///   "client_info": "…", "user_agent": "…"}` (the last two, custom only).
/// `None` (absent claim object) means preset `server`.
pub fn parse_claim(value: Option<&Value>) -> Result<ClaimSpec, String> {
    let Some(value) = value else {
        return Ok(ClaimSpec {
            preset: "server".to_string(),
            custom: None,
        });
    };
    if value.is_null() {
        return Ok(ClaimSpec {
            preset: "server".to_string(),
            custom: None,
        });
    }
    let preset = value
        .get("preset")
        .and_then(|v| v.as_str())
        .unwrap_or("server");
    match preset {
        "server" => Ok(ClaimSpec {
            preset: "server".to_string(),
            custom: None,
        }),
        "apparition" | "sideinstaller" => Ok(ClaimSpec {
            preset: preset.to_string(),
            custom: preset_info(preset),
        }),
        "custom" => {
            let client_info = value
                .get("client_info")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let user_agent = value
                .get("user_agent")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if !valid_header_value(client_info) || !valid_header_value(user_agent) {
                return Err(
                    "custom claim requires non-empty client_info and user_agent with no CR/LF/NUL"
                        .to_string(),
                );
            }
            Ok(ClaimSpec {
                preset: "custom".to_string(),
                custom: Some(AnisetteClientInfo {
                    client_info: client_info.to_string(),
                    user_agent: user_agent.to_string(),
                }),
            })
        }
        other => Err(format!("unknown claim preset: {other}")),
    }
}

/// Parse the optional `content_type` config key.
///
/// Design doc §9 Q1 — Content-Type `text/xml` vs `text/x-xml-plist` —
/// is left open by the design ("decide on-device"). Its stated
/// resolution is a one-line fork patch to isideload IF the on-device
/// spike shows `text/xml` is required for sign-in, because the
/// sign-in path is isideload-owned (`GrandSlam::base_headers` is
/// private) and no FFI change can alter it. This switch therefore
/// applies ONLY to our own apptokens-override path (src/apptokens.rs),
/// where this crate builds the headers itself: it lets the spike test
/// `text/xml` there without a fork, defaulting to isideload's value
/// (`text/x-xml-plist`) so Phase 1 behaviour is unchanged.
/// Sources: Apparition blog, 30 Oct 2026 update (Apple blocks
/// `text/x-xml-plist` on gsd.apple.com with 403 and
/// `application/x-xml-plist` on gsa.apple.com with 403; `text/xml`
/// works on both) — RealRefresh-Research.md §3; design doc §9 Q1
/// notes the rule may be stale/path-specific because iloader
/// demonstrably works with `text/x-xml-plist`, so neither value is
/// assumed correct here — the value is a testable switch, not a guess.
pub fn parse_content_type(value: Option<&Value>) -> Result<&'static str, String> {
    match value {
        None | Some(Value::Null) => Ok(TEXT_XML_PLIST),
        Some(Value::String(s)) => match s.as_str() {
            "text/x-xml-plist" => Ok(TEXT_XML_PLIST),
            "text/xml" => Ok(TEXT_XML),
            other => Err(format!(
                "content_type must be \"text/x-xml-plist\" or \"text/xml\", got: {other}"
            )),
        },
        Some(_) => Err("content_type must be a string".to_string()),
    }
}
