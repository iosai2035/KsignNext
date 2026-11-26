//! Session state and the blocking FFI operations (design doc §5–§6).
//!
//! One `SessionInner` = one Apple ID + one anisette server + one
//! claim set. It owns:
//! * the session's `AnisetteDataGenerator` (shared provider — the
//!   `AppleAccount` built at `login` time clones this generator, so
//!   both sides share the same provider and therefore the same
//!   provisioned anisette identity),
//! * a session-owned `GrandSlam` (built at `session_new`, so the
//!   URL-bag fetch fails fast there, and reused by
//!   `provision_anisette` — the account does not exist yet at that
//!   point, so its own GrandSlam cannot be used),
//! * the logged-in `AppleAccount` (built at `login`, kept for
//!   Phase 2's `DeveloperSession::from_account` on this same handle),
//! * the pending 2FA prompt + its oneshot responder (poll-based
//!   2FA, design doc §5.1.4).
//!
//! Blocking calls run on the global multi-thread tokio runtime
//! (`RUNTIME`) via `block_on`; Swift calls them from background
//! threads, never the main thread, and never from inside a runtime
//! worker thread. Passwords are held only as a `Zeroizing<String>`
//! for the duration of `login` and are never logged, persisted, or
//! put in any JSON.

use std::path::PathBuf;
use std::sync::{
    Arc, Mutex, OnceLock,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::{RwLock, oneshot};
use zeroize::Zeroizing;

use isideload::anisette::{AnisetteClientInfo, AnisetteDataGenerator};
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{
    AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
};
use isideload::auth::grandslam::GrandSlam;
use rootcause::prelude::*;
use serde_json::{Value, json};

use crate::apptokens;
use crate::claims::{self, ClaimSpec};
use crate::errors;
use crate::storage::FileStorage;

/// The opaque session type from `AppleRefreshBridge.h`.
pub struct AppleRefreshSession {
    pub inner: Arc<SessionInner>,
}

#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub server_url: String,
    pub storage_dir: PathBuf,
    pub serial_number: String,
    pub sign_in_claim: ClaimSpec,
    pub err_429_retries: Option<u32>,
    /// Q1 switch (see claims::parse_content_type). Applies only to
    /// the apptokens-override path; the sign-in path keeps
    /// isideload's hardcoded value.
    pub content_type: &'static str,
}

pub struct SessionInner {
    pub config: SessionConfig,
    /// The anisette server's own client_info (fetched live).
    pub server_client_info: AnisetteClientInfo,
    /// The resolved sign-in claim (server's, or the override).
    pub sign_in_client_info: AnisetteClientInfo,
    pub generator: Mutex<AnisetteDataGenerator>,
    pub grandslam: Arc<GrandSlam>,
    pub account: Mutex<Option<AppleAccount>>,
    pub email: Mutex<Option<String>>,
    pub prompt: Mutex<Option<String>>,
    pub responder: Mutex<Option<oneshot::Sender<TwoFactorCallbackResponse>>>,
    pub cancelled: AtomicBool,
}

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static INIT: OnceLock<Result<(), String>> = OnceLock::new();

pub fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build the Apple-refresh tokio runtime")
    })
}

/// One-time global setup: isideload's error-reporting hooks plus the
/// rustls ring CryptoProvider. reqwest is built with
/// `rustls-no-provider`, so **no TLS works until this runs**
/// (design doc §1). Runs once; a failure is stored and reported by
/// every later `session_new` instead of being silently retried.
pub fn ensure_init() -> Result<(), String> {
    INIT.get_or_init(|| {
        isideload::init().map_err(|e| format!("isideload::init failed: {e}"))?;
        rustls::crypto::ring::default_provider()
            .install_default()
            .map_err(|e| format!("failed to install the rustls ring CryptoProvider: {e:?}"))?;
        Ok(())
    })
    .clone()
}

/// One folder per anisette server (AltLoad pattern): the server URL
/// with every non-alphanumeric character replaced by `-`.
fn server_slug(url: &str) -> String {
    let bare = url
        .trim_start_matches("https://")
        .trim_start_matches("http://");
    let slug: String = bare
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "anisette".to_string()
    } else {
        slug.chars().take(64).collect()
    }
}

/// Build a generator for `config`, with `claim_override` applied to
/// its provider (`None` = use the server's own client_info).
fn build_generator(
    config: &SessionConfig,
    claim_override: Option<&AnisetteClientInfo>,
) -> Result<AnisetteDataGenerator, Report> {
    let storage_dir = config.storage_dir.join(server_slug(&config.server_url));
    let storage = FileStorage::new(storage_dir);
    let mut provider = RemoteV3AnisetteProvider::new(
        &config.server_url,
        Box::new(storage),
        config.serial_number.clone(),
    )?;
    if let Some(info) = claim_override {
        provider = provider.set_client_info_override(Some(info.clone()));
    }
    Ok(AnisetteDataGenerator::new(Arc::new(RwLock::new(
        provider,
    ))))
}

fn parse_config(v: &Value) -> Result<SessionConfig, Value> {
    let step = "session_new";
    let server_url = v
        .get("anisette_server_url")
        .and_then(|x| x.as_str())
        .map(|s| s.trim_end_matches('/').to_string())
        .unwrap_or_else(|| claims::DEFAULT_SERVER_URL.to_string());
    if server_url.is_empty()
        || !(server_url.starts_with("https://") || server_url.starts_with("http://"))
    {
        return Err(errors::invalid_argument(
            step,
            "anisette_server_url must be an http(s) URL",
        ));
    }
    // No concrete default is given in the header doc (its storage_dir
    // is a placeholder path); Swift always passes Application Support.
    // Fall back to the temp dir rather than failing the call.
    let storage_dir = v
        .get("storage_dir")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("KsignNext-AppleRefresh"));
    let serial_number = v
        .get("serial_number")
        .and_then(|x| x.as_str())
        .unwrap_or("0")
        .to_string();
    let err_429_retries = match v.get("err_429_retries") {
        None | Some(Value::Null) => Some(10),
        Some(x) => match x.as_u64() {
            Some(n) => Some(n as u32),
            None => {
                return Err(errors::invalid_argument(
                    step,
                    "err_429_retries must be a non-negative integer",
                ));
            }
        },
    };
    let content_type = claims::parse_content_type(v.get("content_type"))
        .map_err(|e| errors::invalid_argument(step, &e))?;
    let sign_in_claim = claims::parse_claim(v.get("sign_in_claim"))
        .map_err(|e| errors::invalid_argument(step, &e))?;
    Ok(SessionConfig {
        server_url,
        storage_dir,
        serial_number,
        sign_in_claim,
        err_429_retries,
        content_type,
    })
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl SessionInner {
    /// Create a session (BLOCKING: `GET {server}/v3/client_info` +
    /// the GSA URL bag). Fails with `anisette_unavailable` /
    /// `network` if either fails.
    pub fn create(config_json: &str) -> Result<(AppleRefreshSession, Value), Value> {
        let step = "session_new";
        ensure_init().map_err(|e| {
            errors::internal(step, &format!("Rust core initialisation failed: {e}"))
        })?;
        let cfg_value: Value = serde_json::from_str(config_json).map_err(|e| {
            errors::invalid_argument(step, &format!("config_json is not valid JSON: {e}"))
        })?;
        let config = parse_config(&cfg_value)?;

        // The server's own client_info, fetched live. When the preset
        // is `server` this is also the sign-in claim, so one fetch
        // serves both; otherwise the resolved claim comes from the
        // override provider (which answers without network).
        let (server_client_info, sign_in_client_info) =
            if config.sign_in_claim.custom.is_none() {
                let generator = build_generator(&config, None)
                    .map_err(|e| errors::from_report(step, &e))?;
                let info = runtime()
                    .block_on(generator.get_client_info())
                    .map_err(|e| errors::from_report(step, &e))?;
                (info.clone(), info)
            } else {
                let server_generator = build_generator(&config, None)
                    .map_err(|e| errors::from_report(step, &e))?;
                let server_info = runtime()
                    .block_on(server_generator.get_client_info())
                    .map_err(|e| errors::from_report(step, &e))?;
                let override_generator =
                    build_generator(&config, config.sign_in_claim.custom.as_ref())
                        .map_err(|e| errors::from_report(step, &e))?;
                let resolved = runtime()
                    .block_on(override_generator.get_client_info())
                    .map_err(|e| errors::from_report(step, &e))?;
                (server_info, resolved)
            };

        // Fail fast on the GSA URL bag, fetched with the sign-in
        // claim (design doc §3). This GrandSlam is also the one
        // provision_anisette uses — the account (and its own
        // GrandSlam) does not exist until login.
        let grandslam = runtime()
            .block_on(GrandSlam::new(sign_in_client_info.clone(), false, None))
            .map_err(|e| errors::from_report(step, &e))?;

        let generator = build_generator(&config, config.sign_in_claim.custom.as_ref())
            .map_err(|e| errors::from_report(step, &e))?;
        let inner = Arc::new(SessionInner {
            config: config.clone(),
            server_client_info,
            sign_in_client_info: sign_in_client_info.clone(),
            generator: Mutex::new(generator),
            grandslam: Arc::new(grandslam),
            account: Mutex::new(None),
            email: Mutex::new(None),
            prompt: Mutex::new(None),
            responder: Mutex::new(None),
            cancelled: AtomicBool::new(false),
        });
        let success = json!({
            "ok": true,
            "server": config.server_url,
            "client_info": sign_in_client_info.client_info,
            "user_agent": sign_in_client_info.user_agent,
        });
        Ok((AppleRefreshSession { inner }, success))
    }

    /// Delete the stored anisette identity and replace the session
    /// generator with a fresh one (so the provider's in-memory state
    /// is dropped too). Note: an already-logged-in account keeps its
    /// own cloned generator until the next login.
    pub fn reset_anisette(&self) -> Result<Value, Value> {
        let step = "reset_anisette";
        let state_path = self
            .config
            .storage_dir
            .join(server_slug(&self.config.server_url))
            .join("anisette_state");
        match std::fs::remove_file(&state_path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(errors::internal(
                    step,
                    &format!("Failed to delete stored anisette state: {e}"),
                ));
            }
        }
        let fresh = build_generator(&self.config, self.config.sign_in_claim.custom.as_ref())
            .map_err(|e| errors::from_report(step, &e))?;
        *lock(&self.generator) = fresh;
        Ok(json!({"ok": true, "reset": true}))
    }

    /// Provision (or reuse) the anisette identity and fetch fresh
    /// headers once. A -45061 from the server triggers an automatic
    /// re-provision inside isideload (up to 3 attempts).
    pub fn provision_anisette(&self, force_reset: bool) -> Result<Value, Value> {
        let step = "provision_anisette";
        if force_reset {
            self.reset_anisette()?;
        }
        let gs = Arc::clone(&self.grandslam);
        let mut guard = lock(&self.generator);
        runtime()
            .block_on(guard.get_anisette_data(gs))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({
            "ok": true,
            "provisioned": true,
            "server": self.config.server_url,
            "client_info": self.sign_in_client_info.client_info,
            "user_agent": self.sign_in_client_info.user_agent,
        }))
    }

    /// Sign in with the Apple ID password (BLOCKING). Drives
    /// isideload's `AppleAccount::login` (SRP init + complete, with
    /// 2FA via the poll/respond functions). The account is stored on
    /// the session whether login succeeds or fails, so a later call
    /// can inspect it — but only a successful login leaves it usable.
    pub fn login(self: &Arc<Self>, email: &str, password: &str) -> Result<Value, Value> {
        let step = "login";
        if email.trim().is_empty() {
            return Err(errors::invalid_argument(step, "email must not be empty"));
        }
        if password.is_empty() {
            return Err(errors::invalid_argument(step, "password must not be empty"));
        }
        self.cancelled.store(false, Ordering::SeqCst);
        *lock(&self.email) = Some(email.to_string());

        // The account is built here (not at session_new) so a wrong
        // email does not poison the session — design doc §6.2.
        // `AppleAccount::new` fetches the client_info and the GSA URL
        // bag itself. The generator is cloned: the clone shares the
        // session provider (same Arc), so provisioning done through
        // the session is visible to the account.
        let generator = lock(&self.generator).clone();
        let mut account = runtime()
            .block_on(AppleAccount::new(
                email,
                generator,
                false,
                None,
                self.config.err_429_retries,
            ))
            .map_err(|e| errors::from_report(step, &e))?;

        // Poll-based 2FA (design doc §5.1.4): the callback stores the
        // prompt JSON, stores a fresh oneshot Sender, and awaits the
        // Receiver — fully async, no thread blocked, no C callback
        // into Swift. `respond_2fa` / `cancel` send on that Sender.
        let inner_cb = Arc::clone(self);
        let callback = move |params: TwoFactorCallbackParams| {
            let inner_cb = Arc::clone(&inner_cb);
            async move {
                if inner_cb.cancelled.load(Ordering::SeqCst) {
                    return Ok(TwoFactorCallbackResponse::Abort);
                }
                let prompt_json = match serde_json::to_string(&params) {
                    Ok(j) => j,
                    Err(e) => {
                        return Err(report!("Failed to serialise 2FA prompt: {e}"));
                    }
                };
                let (tx, rx) = oneshot::channel();
                {
                    *lock(&inner_cb.prompt) = Some(prompt_json);
                    *lock(&inner_cb.responder) = Some(tx);
                }
                match rx.await {
                    Ok(response) => Ok(response),
                    // The responder was dropped (cancel / session
                    // teardown): abort the login.
                    Err(_) => Ok(TwoFactorCallbackResponse::Abort),
                }
            }
        };

        // The password lives only in this Zeroizing<String> for the
        // duration of the call; it is zeroed on drop below, never
        // logged, never persisted, never put in any JSON.
        let password_z = Zeroizing::new(password.to_string());
        let login_result = runtime().block_on(account.login(password_z.as_str(), callback));
        drop(password_z);
        // The 2FA handshake is over either way: clear any stale
        // prompt/responder so a later poll cannot see it.
        *lock(&self.prompt) = None;
        *lock(&self.responder) = None;
        *lock(&self.account) = Some(account);
        login_result.map_err(|e| errors::from_report(step, &e))?;

        let guard = lock(&self.account);
        let acc = guard.as_ref().ok_or_else(|| {
            errors::internal(step, "Logged in but the account is missing")
        })?;
        let (first_name, last_name) = acc
            .get_name()
            .map(|(f, l)| (Some(f), Some(l)))
            .unwrap_or((None, None));
        let adsid = acc
            .spd
            .as_ref()
            .and_then(|d| d.get("adsid"))
            .and_then(|v| v.as_string())
            .map(|s| s.to_string());
        Ok(json!({
            "ok": true,
            "email": email,
            "first_name": first_name,
            "last_name": last_name,
            "adsid": adsid,
        }))
    }

    /// The pending 2FA prompt, if the login callback is waiting for
    /// an answer. The prompt JSON is isideload's
    /// `TwoFactorCallbackParams` serialised verbatim (camelCase).
    pub fn poll_prompt(&self) -> Value {
        if lock(&self.responder).is_none() {
            return json!({"pending": false});
        }
        match lock(&self.prompt)
            .clone()
            .and_then(|p| serde_json::from_str::<Value>(&p).ok())
        {
            Some(prompt) => json!({"pending": true, "prompt": prompt}),
            None => json!({"pending": false}),
        }
    }

    /// Answer a pending 2FA prompt. A wrong code does NOT fail
    /// login: isideload re-prompts (see poll_prompt's last_error).
    pub fn respond_2fa(&self, response_json: &str) -> Result<Value, Value> {
        let step = "respond_2fa";
        let value: Value = serde_json::from_str(response_json).map_err(|e| {
            errors::invalid_argument(step, &format!("response_json is not valid JSON: {e}"))
        })?;
        let action = value
            .get("action")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let response = match action {
            "code" => {
                let code = value
                    .get("code")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(errors::invalid_argument(
                        step,
                        "2FA code must be exactly 6 digits",
                    ));
                }
                TwoFactorCallbackResponse::SubmitCode(code.to_string())
            }
            "sms" => {
                let id = value.get("id").and_then(|v| v.as_u64()).ok_or_else(|| {
                    errors::invalid_argument(step, "\"sms\" requires an integer \"id\"")
                })?;
                TwoFactorCallbackResponse::SendSms(id as u32)
            }
            "devices" => TwoFactorCallbackResponse::SendToDevices,
            "resend" => TwoFactorCallbackResponse::ResendCode,
            "abort" => TwoFactorCallbackResponse::Abort,
            _ => {
                return Err(errors::invalid_argument(
                    step,
                    "action must be one of: code, sms, devices, resend, abort",
                ));
            }
        };
        let mut responder = lock(&self.responder);
        let tx = match responder.take() {
            Some(tx) => tx,
            None => {
                return Err(errors::error_value(
                    step,
                    "no_prompt_pending",
                    "No 2FA prompt is pending on this session",
                    None,
                    None,
                    None,
                ));
            }
        };
        *lock(&self.prompt) = None;
        match tx.send(response) {
            Ok(()) => Ok(json!({"ok": true, "accepted": true})),
            Err(_) => Err(errors::error_value(
                step,
                "no_prompt_pending",
                "No 2FA prompt is pending on this session",
                None,
                None,
                None,
            )),
        }
    }

    /// Ask a blocked login to stop at the next 2FA boundary. A login
    /// stuck in a bare network read (no isideload timeout on GSA
    /// requests) only returns on the OS TCP timeout — Swift must
    /// still treat the session as dead after cancel and create a
    /// fresh session for the next attempt.
    pub fn cancel(&self) -> Value {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(tx) = lock(&self.responder).take() {
            let _ = tx.send(TwoFactorCallbackResponse::Abort);
        }
        *lock(&self.prompt) = None;
        json!({"ok": true, "cancelled": true})
    }

    /// Fetch the app token for `app` (BLOCKING). With no claim
    /// override this is isideload's own `get_app_token`; with one
    /// it is the override path in `apptokens.rs`. Only token
    /// metadata is returned — never the token value (§5.1.6).
    pub fn get_app_token(
        &self,
        app: &str,
        claim_json: Option<&str>,
    ) -> Result<Value, Value> {
        let step = "get_app_token";
        if app.trim().is_empty() {
            return Err(errors::invalid_argument(step, "app must not be empty"));
        }
        let app_norm = normalise_app(app);
        let claim = match claim_json {
            None => None,
            Some(s) => {
                let value: Value = serde_json::from_str(s).map_err(|e| {
                    errors::invalid_argument(
                        step,
                        &format!("apptokens_claim_json is not valid JSON: {e}"),
                    )
                })?;
                Some(
                    claims::parse_claim(Some(&value))
                        .map_err(|e| errors::invalid_argument(step, &e))?,
                )
            }
        };
        let mut guard = lock(&self.account);
        let account = guard.as_mut().ok_or_else(|| {
            errors::error_value(
                step,
                "session_invalid",
                "No account on this session — call login first",
                None,
                None,
                None,
            )
        })?;
        if account.spd.is_none() {
            return Err(errors::error_value(
                step,
                "session_invalid",
                "Not logged in on this session",
                None,
                None,
                None,
            ));
        }
        let meta = match claim {
            None => {
                let token = runtime()
                    .block_on(account.get_app_token(&app_norm))
                    .map_err(|e| errors::from_report(step, &e))?;
                apptokens::TokenMeta {
                    token_length: token.token.len(),
                    duration: token.duration,
                    expiry: token.expiry,
                }
            }
            Some(claim_spec) => {
                // An override claim must resolve to concrete strings;
                // preset "server" here means "reuse the sign-in
                // claim", which is the NULL path — but a caller may
                // still pass it explicitly, so resolve it to the
                // session's sign-in claim.
                let info = match claim_spec.custom {
                    Some(info) => info,
                    None => self.sign_in_client_info.clone(),
                };
                runtime()
                    .block_on(apptokens::get_app_token_with_claim(
                        account,
                        &app_norm,
                        &info,
                        self.config.content_type,
                        self.config.err_429_retries,
                    ))
                    .map_err(|e| errors::from_report(step, &e))?
            }
        };
        Ok(json!({
            "ok": true,
            "app": app_norm,
            "duration": meta.duration,
            "expiry": meta.expiry,
            "token_length": meta.token_length,
            "has_token": true,
        }))
    }

    pub fn session_info(&self) -> Value {
        let email = lock(&self.email).clone().unwrap_or_default();
        let guard = lock(&self.account);
        let (first_name, last_name, adsid, logged_in) = match guard.as_ref() {
            Some(acc) => {
                let (first, last) = acc
                    .get_name()
                    .map(|(f, l)| (Some(f), Some(l)))
                    .unwrap_or((None, None));
                let adsid = acc
                    .spd
                    .as_ref()
                    .and_then(|d| d.get("adsid"))
                    .and_then(|v| v.as_string())
                    .map(|s| s.to_string());
                (first, last, adsid, acc.spd.is_some())
            }
            None => (None, None, None, false),
        };
        json!({
            "ok": true,
            "email": email,
            "first_name": first_name,
            "last_name": last_name,
            "adsid": adsid,
            "logged_in": logged_in,
            "server": self.config.server_url,
            "sign_in_claim": self.sign_in_client_info.client_info,
        })
    }

    /// No network. The `server` preset is the live server info
    /// fetched at session_new; the other two are the fixed presets
    /// from §5.3 (matching the header's documented shape).
    pub fn sign_in_claims(&self) -> Value {
        json!({
            "ok": true,
            "server_client_info": self.server_client_info.client_info,
            "server_user_agent": self.server_client_info.user_agent,
            "presets": {
                "server": {
                    "client_info": self.server_client_info.client_info,
                    "user_agent": self.server_client_info.user_agent,
                },
                "apparition": {
                    "client_info": claims::APPARITION_CLIENT_INFO,
                    "user_agent": claims::APPARITION_USER_AGENT,
                },
                "sideinstaller": {
                    "client_info": claims::SIDEINSTALLER_CLIENT_INFO,
                    "user_agent": claims::SIDEINSTALLER_USER_AGENT,
                },
            },
        })
    }
}

/// `AppleAccount::get_app_token` normalises the same way: an app
/// without the `com.apple.gs.` prefix gets it prepended.
fn normalise_app(app: &str) -> String {
    if app.contains("com.apple.gs.") {
        app.to_string()
    } else {
        format!("com.apple.gs.{app}")
    }
}
