//! Developer services (Phase 2) — teams, devices, App IDs,
//! development certificates and provisioning profiles, on the same
//! session handle as sign-in (design doc `Phase1-FFI-Design.md`
//! §5, and `RealRefresh-Research.md` §5/§11).
//!
//! Everything here runs on the `DeveloperSession` built from the
//! signed-in `AppleAccount` (`DeveloperSession::from_account`):
//! it fetches the `com.apple.gs.xcode.auth` app token and keeps it
//! inside Rust — the token value is never returned to Swift, it
//! only travels as the `X-Apple-GS-Token` HTTP header. The session
//! is cached on the handle for 30 minutes and rebuilt on demand
//! when it expires (there is no token-refresh method in isideload).
//!
//! All calls are BLOCKING (network inside) and run on the same
//! tokio runtime as sign-in. Every function returns the uniform
//! JSON envelope (`ffi::run`); Apple server errors arrive as
//! `SideloadError::DeveloperError(code, message)` and are mapped
//! by `errors::from_report` to code `"developer_error"` with the
//! Apple code in `apple_ec` — Swift branches on it (e.g. 7460 =
//! maximum certificates reached, 35 = already registered).
//!
//! Certificate creation follows isideload's
//! `CertificateIdentity::retrieve` exactly: the RSA-2048 private
//! key is generated once and stored file-backed under
//! `<storage_dir>/certs/<sha256(email)>/key` (PKCS#8 DER, base64 —
//! isideload's own convention; the key never leaves the app
//! container), an existing certificate matching that key and the
//! machine name is reused, otherwise a CSR is built with rcgen
//! and submitted; the issued certificate is packaged as a .p12
//! (p12-keystore) with a fresh random password that is returned
//! to Swift once so it can be stored in the Keychain. The .p12
//! bytes are what Swift registers in the existing Certificates
//! store, so the signing pipeline needs no change. When the
//! certificate limit is hit (DeveloperError 7460) this layer
//! fails with that code and Swift shows the certificate list so
//! the user can revoke one and retry — nothing is revoked
//! automatically.
//!
//! App groups are deliberately NOT exposed here: an app group is
//! only needed when the signed app itself uses one, and Ksign
//! Next registers plain App IDs. `add_increased_memory_limit`
//! (the non-QH JSON:API call) is likewise out of scope.

use std::collections::HashSet;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use isideload::dev::app_ids::{AppId, AppIdsApi, Profile};
use isideload::dev::certificates::{CertificatesApi, DevelopmentCertificate};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::{DeveloperDevice, DevicesApi};
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use isideload::sideload::builder::MaxCertsBehavior;
use isideload::sideload::cert_identity::CertificateIdentity;
use rootcause::prelude::*;
use serde_json::{json, Value};

use crate::errors;
use crate::session::{runtime, SessionInner};
use crate::storage::FileStorage;

/// How long a cached DeveloperSession (and its Xcode token) is
/// reused before a fresh `from_account` rebuilds it.
const DEV_SESSION_TTL: Duration = Duration::from_secs(30 * 60);

/// The machine name the on-device certificate is registered
/// under is supplied by Swift (see `DeveloperServiceClient`); it
/// must stay stable per install so a later run finds and reuses
/// the same certificate instead of creating a new one each time.
/// A cached DeveloperSession plus when it was built.
pub struct DevSessionEntry {
    pub session: DeveloperSession,
    pub built_at: Instant,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn not_signed_in(step: &str) -> Value {
    errors::error_value(
        step,
        "not_signed_in",
        "Sign in with an Apple ID first",
        None,
        None,
        None,
    )
}

pub(crate) fn req_str<'a>(req: &'a Value, step: &str, key: &str) -> Result<&'a str, Value> {
    req.get(key)
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            errors::invalid_argument(
                step,
                &format!("request_json needs a non-empty \"{key}\" string"),
            )
        })
}

fn date_str(date: &plist::Date) -> String {
    date.to_xml_format()
}

fn opt_date_str(date: &Option<plist::Date>) -> Option<String> {
    date.as_ref().map(date_str)
}

fn unix_seconds(date: &plist::Date) -> i64 {
    SystemTime::from(*date)
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Standard base64 (RFC 4648, padded). `base64` is not a direct
/// dependency of this crate and the lock file must stay untouched,
/// so this is hand-rolled for the binary blobs (.p12, .mobileprovision).
fn b64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// A fresh random password for the generated .p12 (24 bytes from
/// /dev/urandom, hex-encoded). Never logged; returned once to
/// Swift so it can be stored in the Keychain.
fn random_password() -> String {
    let mut bytes = [0u8; 24];
    let filled = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| {
            use std::io::Read;
            f.read_exact(&mut bytes)
        })
        .is_ok();
    if !filled {
        // Fallback: time + pid mixed into the buffer (never fail
        // the whole certificate flow for a random source).
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = ((nanos >> ((i % 16) * 4)) & 0xff) as u8 ^ (std::process::id() as u128 >> (i % 4 * 8)) as u8;
        }
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn team_json(t: &DeveloperTeam) -> Value {
    json!({
        "team_id": t.team_id,
        "name": t.name,
        "type": t.r#type,
        "status": t.status,
    })
}

fn device_json(d: &DeveloperDevice) -> Value {
    json!({
        "device_id": d.device_id,
        "device_number": d.device_number,
        "name": d.name,
        "status": d.status,
    })
}

fn app_id_json(a: &AppId) -> Value {
    json!({
        "app_id_id": a.app_id_id,
        "identifier": a.identifier,
        "name": a.name,
        "expiration_date": opt_date_str(&a.expiration_date),
    })
}

fn cert_json(c: &DevelopmentCertificate) -> Value {
    json!({
        "certificate_id": c.certificate_id,
        "name": c.name,
        "serial_number": c.serial_number,
        "machine_id": c.machine_id,
        "machine_name": c.machine_name,
        "status": c.status,
        "status_code": c.status_code,
        "expiration_date": opt_date_str(&c.expiration_date),
    })
}

fn profile_json(p: &Profile) -> Value {
    json!({
        "provisioning_profile_id": p.provisioning_profile_id,
        "name": p.name,
        "status": p.status,
        "type": p.r#type,
        "distribution_method": p.distribution_method,
        "uuid": p.uuid,
        "date_expire": date_str(&p.date_expire),
        "date_expire_unix": unix_seconds(&p.date_expire),
        "app_id_id": p.app_id_id,
        "filename": p.filename,
        "is_free_provisioning_profile": p.is_free_provisioning_profile,
        "encoded_profile_base64": b64(p.encoded_profile.as_ref()),
    })
}

impl SessionInner {
    /// The cached DeveloperSession for this handle, rebuilt when
    /// absent or older than DEV_SESSION_TTL. Requires a login;
    /// fails with `not_signed_in` otherwise. The returned session
    /// is a clone (it shares the underlying client/token), so the
    /// caller can hold `&mut` on it without holding any lock.
    pub fn dev_session(&self) -> Result<DeveloperSession, Value> {
        let step = "developer_session";
        if let Some(entry) = lock(&self.dev_session).as_ref() {
            if entry.built_at.elapsed() < DEV_SESSION_TTL {
                return Ok(entry.session.clone());
            }
        }
        let mut account_guard = lock(&self.account);
        let account = match account_guard.as_mut() {
            Some(a) => a,
            None => return Err(not_signed_in(step)),
        };
        let fresh = runtime()
            .block_on(DeveloperSession::from_account(account))
            .map_err(|e| errors::from_report(step, &e))?;
        *lock(&self.dev_session) = Some(DevSessionEntry {
            session: fresh.clone(),
            built_at: Instant::now(),
        });
        Ok(fresh)
    }

    fn find_team(
        &self,
        dev: &mut DeveloperSession,
        team_id: &str,
        step: &str,
    ) -> Result<DeveloperTeam, Value> {
        let teams = runtime()
            .block_on(dev.list_teams())
            .map_err(|e| errors::from_report(step, &e))?;
        teams
            .into_iter()
            .find(|t| t.team_id == team_id)
            .ok_or_else(|| {
                errors::invalid_argument(step, &format!("no developer team with id {team_id}"))
            })
    }

    fn find_app_id(
        &self,
        dev: &mut DeveloperSession,
        team: &DeveloperTeam,
        app_id_id: &str,
        step: &str,
    ) -> Result<AppId, Value> {
        let list = runtime()
            .block_on(dev.list_app_ids(team, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        list.app_ids
            .into_iter()
            .find(|a| a.app_id_id == app_id_id)
            .ok_or_else(|| {
                errors::invalid_argument(step, &format!("no App ID with id {app_id_id}"))
            })
    }

    /// List the developer teams of the signed-in account.
    pub fn list_teams(&self) -> Result<Value, Value> {
        let step = "list_teams";
        let mut dev = self.dev_session()?;
        let teams = runtime()
            .block_on(dev.list_teams())
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "teams": teams.iter().map(team_json).collect::<Vec<_>>() }))
    }

    /// List the devices registered on a team.
    pub fn list_devices(&self, team_id: &str) -> Result<Value, Value> {
        let step = "list_devices";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let devices = runtime()
            .block_on(dev.list_devices(&team, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "devices": devices.iter().map(device_json).collect::<Vec<_>>() }))
    }

    /// Register this device on the team if it is not already
    /// registered (idempotent). Returns the registered device.
    pub fn ensure_device(&self, team_id: &str, name: &str, udid: &str) -> Result<Value, Value> {
        let step = "ensure_device";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        runtime()
            .block_on(dev.ensure_device_registered(&team, name, udid, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        let devices = runtime()
            .block_on(dev.list_devices(&team, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        let device = devices
            .into_iter()
            .find(|d| d.device_number == udid)
            .ok_or_else(|| {
                errors::internal(step, "device was registered but is not listed by Apple")
            })?;
        Ok(json!({ "ok": true, "registered": true, "device": device_json(&device) }))
    }

    /// List the App IDs of a team, with the free-account quota.
    pub fn list_app_ids(&self, team_id: &str) -> Result<Value, Value> {
        let step = "list_app_ids";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let list = runtime()
            .block_on(dev.list_app_ids(&team, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({
            "ok": true,
            "app_ids": list.app_ids.iter().map(app_id_json).collect::<Vec<_>>(),
            "max_quantity": list.max_quantity,
            "available_quantity": list.available_quantity,
        }))
    }

    /// Register a new App ID for a bundle identifier. The name is
    /// normalised by isideload (non-alphanumeric chars stripped).
    pub fn add_app_id(&self, team_id: &str, name: &str, identifier: &str) -> Result<Value, Value> {
        let step = "add_app_id";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let app_id = runtime()
            .block_on(dev.add_app_id(&team, name, identifier, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "app_id": app_id_json(&app_id) }))
    }

    /// List the iOS development certificates of a team.
    pub fn list_certificates(&self, team_id: &str) -> Result<Value, Value> {
        let step = "list_certificates";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let certs = runtime()
            .block_on(dev.list_ios_certs(&team))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "certificates": certs.iter().map(cert_json).collect::<Vec<_>>() }))
    }

    /// Reuse or create the development certificate for this
    /// machine. Returns the .p12 bytes (base64) and its one-time
    /// password, plus the certificate identity. On DeveloperError
    /// 7460 (certificate limit) the error carries `apple_ec` 7460
    /// and Swift must offer revocation instead of retrying.
    pub fn create_certificate(
        &self,
        team_id: &str,
        machine_name: &str,
        email: &str,
    ) -> Result<Value, Value> {
        let step = "create_certificate";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let storage = FileStorage::new(self.config.storage_dir.join("certs"));
        let before: HashSet<String> = runtime()
            .block_on(dev.list_ios_certs(&team))
            .map_err(|e| errors::from_report(step, &e))?
            .into_iter()
            .filter_map(|c| c.serial_number)
            .collect();
        // No prompt callback exists across FFI: at the limit this
        // fails with DeveloperError 7460 and the UI offers revoke.
        type NoPrompt = fn(
            Vec<DevelopmentCertificate>,
        ) -> std::future::Ready<Result<Option<Vec<String>>, Report>>;
        let behavior: MaxCertsBehavior<NoPrompt> = MaxCertsBehavior::Error;
        let identity = runtime()
            .block_on(CertificateIdentity::retrieve(
                machine_name,
                email,
                &mut dev,
                &team,
                &storage,
                &behavior,
            ))
            .map_err(|e| errors::from_report(step, &e))?;
        let password = random_password();
        let p12 = runtime()
            .block_on(identity.as_p12(&password))
            .map_err(|e| errors::from_report(step, &e))?;
        let serial = identity.get_serial_number();
        let reused = before.contains(&serial);
        let not_after = runtime()
            .block_on(dev.list_ios_certs(&team))
            .map_err(|e| errors::from_report(step, &e))?
            .into_iter()
            .find(|c| c.serial_number.as_deref() == Some(serial.as_str()))
            .and_then(|c| opt_date_str(&c.expiration_date));
        Ok(json!({
            "ok": true,
            "reused": reused,
            "machine_id": identity.machine_id,
            "machine_name": identity.machine_name,
            "serial_number": serial,
            "not_after": not_after,
            "p12_base64": b64(&p12),
            "p12_password": password,
        }))
    }

    /// Revoke a development certificate by serial number.
    pub fn revoke_certificate(&self, team_id: &str, serial_number: &str) -> Result<Value, Value> {
        let step = "revoke_certificate";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        runtime()
            .block_on(dev.revoke_development_cert(&team, serial_number, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "revoked": true }))
    }

    /// Download the team provisioning profile for an App ID.
    /// `encoded_profile_base64` is the raw .mobileprovision file.
    pub fn download_profile(&self, team_id: &str, app_id_id: &str) -> Result<Value, Value> {
        let step = "download_profile";
        let mut dev = self.dev_session()?;
        let team = self.find_team(&mut dev, team_id, step)?;
        let app_id = self.find_app_id(&mut dev, &team, app_id_id, step)?;
        let profile = runtime()
            .block_on(dev.download_team_provisioning_profile(&team, &app_id, Option::<DeveloperDeviceType>::None))
            .map_err(|e| errors::from_report(step, &e))?;
        Ok(json!({ "ok": true, "profile": profile_json(&profile) }))
    }
}

/// Parse a request-JSON argument of a dev FFI function.
pub fn read_request_json(ptr: *const std::os::raw::c_char, step: &str) -> Result<Value, Value> {
    let text = unsafe { crate::ffi::read_str(ptr, step, "request_json")? };
    serde_json::from_str(&text)
        .map_err(|e| errors::invalid_argument(step, &format!("request_json is not valid JSON: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use isideload::dev::app_ids::ListAppIdsResponse;
    use isideload::dev::certificates::DevelopmentCertificate;
    use isideload::dev::devices::DeveloperDevice;
    use isideload::dev::teams::DeveloperTeam;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foob"), "Zm9vYg==");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
        // Binary with every byte value round-trips the alphabet.
        let all: Vec<u8> = (0..=255).collect();
        let encoded = b64(&all);
        assert_eq!(encoded.len(), 344);
        assert!(encoded.ends_with("=="));
    }

    #[test]
    fn random_password_is_hex_and_long() {
        let p = random_password();
        assert_eq!(p.len(), 48);
        assert!(p.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(p, random_password());
    }

    #[test]
    fn team_json_uses_camel_case_keys() {
        let team: DeveloperTeam = serde_json::from_value(json!({
            "teamId": "TEAM123",
            "name": "Mohammed",
            "type": "Individual",
            "status": "active",
        }))
        .unwrap();
        let out = team_json(&team);
        assert_eq!(out["team_id"], "TEAM123");
        assert_eq!(out["name"], "Mohammed");
        assert_eq!(out["type"], "Individual");
        assert_eq!(out["status"], "active");
    }

    #[test]
    fn device_json_carries_udid_as_device_number() {
        let device: DeveloperDevice = serde_json::from_value(json!({
            "deviceId": "DEV1",
            "deviceNumber": "0000802000112233445566778899AABBCCDDEEFF",
            "name": "iPhone",
            "status": "active",
        }))
        .unwrap();
        let out = device_json(&device);
        assert_eq!(
            out["device_number"],
            "0000802000112233445566778899AABBCCDDEEFF"
        );
    }

    #[test]
    fn app_id_json_keeps_expiry_as_iso_string() {
        let list: ListAppIdsResponse = serde_json::from_value(json!({
            "appIds": [{
                "appIdId": "APP1",
                "identifier": "com.example.app",
                "name": "Example",
                "features": {},
                "expirationDate": "2026-12-03T13:00:00Z",
            }],
            "maxQuantity": 10,
            "availableQuantity": 9,
        }))
        .unwrap();
        let out = app_id_json(&list.app_ids[0]);
        assert_eq!(out["app_id_id"], "APP1");
        assert_eq!(out["identifier"], "com.example.app");
        assert_eq!(out["expiration_date"], "2026-12-03T13:00:00Z");
    }

    #[test]
    fn cert_json_keeps_optional_fields_nullable() {
        let cert: DevelopmentCertificate = serde_json::from_value(json!({
            "certificateId": "CERT1",
            "name": "iPhone Developer",
            "serialNumber": "A1B2C3",
            "machineId": "MACHINE1",
            "machineName": "KsignNext",
            "status": "Issued",
            "statusCode": 0,
            "expirationDate": "2027-11-26T00:00:00Z",
        }))
        .unwrap();
        let out = cert_json(&cert);
        assert_eq!(out["serial_number"], "A1B2C3");
        assert_eq!(out["machine_name"], "KsignNext");
        assert_eq!(out["expiration_date"], "2027-11-26T00:00:00Z");
    }

    #[test]
    fn profile_json_base64_encodes_the_raw_profile() {
        // plist::Data has no JSON deserializer, so the struct is
        // built directly rather than from a JSON fixture.
        let profile = Profile {
            encoded_profile: plist::Data::from(vec![0x30, 0x82, 0x01, 0x00]),
            filename: "profile.mobileprovision".to_string(),
            provisioning_profile_id: "PROF1".to_string(),
            name: "iOS Team Provisioning Profile: com.example.app".to_string(),
            status: "Active".to_string(),
            r#type: "Development".to_string(),
            distribution_method: "adhoc".to_string(),
            pro_pro_platorm: None,
            uuid: "11111111-2222-3333-4444-555555555555".to_string(),
            date_expire: plist::Date::from_xml_format("2026-12-03T13:00:00Z").unwrap(),
            managing_app: None,
            app_id_id: "APP1".to_string(),
            is_template_profile: false,
            is_team_profile: None,
            is_free_provisioning_profile: Some(true),
        };
        let out = profile_json(&profile);
        assert_eq!(out["uuid"], "11111111-2222-3333-4444-555555555555");
        assert_eq!(out["date_expire"], "2026-12-03T13:00:00Z");
        assert_eq!(out["date_expire_unix"], 1796302800);
        assert_eq!(out["encoded_profile_base64"], b64(&[0x30, 0x82, 0x01, 0x00]));
        assert_eq!(out["is_free_provisioning_profile"], true);
    }

    #[test]
    fn request_json_rejects_missing_keys() {
        let req = json!({ "team_id": "T1" });
        assert!(req_str(&req, "test", "udid").is_err());
        assert_eq!(req_str(&req, "test", "team_id").unwrap(), "T1");
        let empty = json!({ "udid": "" });
        assert!(req_str(&empty, "test", "udid").is_err());
    }
}
