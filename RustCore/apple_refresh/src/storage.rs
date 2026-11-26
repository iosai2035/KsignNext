//! File-backed `SideloadingStorage` for the anisette identity
//! (design doc §6.2 `storage.rs`).
//!
//! One file per key under `<storage_dir>/<server-slug>/`, e.g.
//! `anisette_state` (plist bytes). One folder per anisette server
//! (AltLoad pattern). The stored state is a device identity blob,
//! not a secret — but it still lives in Application Support, never
//! in a shared container, and is never logged.
//!
//! The trait's default `store_data`/`retrieve_data` base64-encode,
//! so this implementation only needs `store`/`retrieve` (plain
//! text files) plus a real `delete` that removes the file.

use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;
use std::fs;
use std::path::PathBuf;

pub struct FileStorage {
    dir: PathBuf,
}

impl FileStorage {
    pub fn new(dir: PathBuf) -> Self {
        FileStorage { dir }
    }

    fn key_path(&self, key: &str) -> Result<PathBuf, Report> {
        // The certificate private key lives under "<sha256(email)>/key"
        // (isideload's convention, see dev.rs). That one sub-path is
        // allowed; everything else must be a flat file name.
        let is_cert_key = key.len() == 68
            && key.ends_with("/key")
            && key[..64].chars().all(|c| c.is_ascii_hexdigit());
        if key.is_empty()
            || key.contains('\\')
            || key.contains("..")
            || key.contains('\0')
            || (!is_cert_key && key.contains('/'))
        {
            return Err(report!("Invalid storage key"));
        }
        Ok(self.dir.join(key))
    }
}

impl SideloadingStorage for FileStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let path = self.key_path(key)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| report!("Failed to create storage directory: {e}"))?;
        }
        fs::write(&path, value.as_bytes())
            .map_err(|e| report!("Failed to write storage file: {e}"))?;
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let path = self.key_path(key)?;
        match fs::read(&path) {
            Ok(data) => Ok(Some(String::from_utf8_lossy(&data).into_owned())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(report!("Failed to read storage file: {e}")),
        }
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        let path = self.key_path(key)?;
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(report!("Failed to delete storage file: {e}")),
        }
    }
}
