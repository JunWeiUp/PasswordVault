//! Preview-only native services. Secret bytes never enter the JavaScript bridge.
#[cfg(target_os = "macos")]
mod services;
#[cfg(target_os = "macos")]
pub use services::*;

pub fn verify_enrollment(session: &vault_core::VaultSession, directory: &std::path::Path, password: String) -> Result<zeroize::Zeroizing<Vec<u8>>, String> {
    // Refuse enrollment while locked, even if the supplied password is correct.
    let previous = zeroize::Zeroizing::new(session.biometric_key().map_err(super::error_code)?);
    let password = zeroize::Zeroizing::new(password);
    let bytes = std::fs::read(directory.join("vault/header.json")).map_err(|_| "Storage".to_string())?;
    if bytes.len() > 16384 { return Err("InvalidData".into()); }
    let header: vault_core::Header = serde_json::from_slice(&bytes).map_err(|_| "InvalidData".to_string())?;
    let verified = header.unlock(&password).map_err(super::error_code)?;
    if previous.as_slice() != verified.as_slice() { return Err("Authentication".into()); }
    let current = zeroize::Zeroizing::new(session.biometric_key().map_err(super::error_code)?);
    if *previous != *current { return Err("Authentication".into()); }
    Ok(current)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn enrollment_requires_unlocked_session_and_correct_password() {
        let path = std::env::temp_dir().join(format!("pv-nsh-biometric-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let session = vault_core::VaultSession::new(path.to_string_lossy().into_owned()).unwrap();
        session.command(r#"{"op":"create","password":"synthetic-test-password"}"#.into()).unwrap();
        let root = zeroize::Zeroizing::new(session.biometric_key().unwrap());
        assert_eq!(verify_enrollment(&session, &path, "wrong-password".into()).unwrap_err(), "Authentication");
        assert_eq!(*root, session.biometric_key().unwrap());
        assert_eq!(*root, *verify_enrollment(&session, &path, "synthetic-test-password".into()).unwrap());
        session.command(r#"{"op":"lock"}"#.into()).unwrap();
        assert_eq!(verify_enrollment(&session, &path, "synthetic-test-password".into()).unwrap_err(), "Locked");
        assert!(session.unlock_biometric(vec![0; 31]).is_err());
        assert!(session.unlock_biometric(vec![0; 32]).is_err());
        session.unlock_biometric(root.to_vec()).unwrap();
        drop(session);
        std::fs::remove_dir_all(path).unwrap();
    }
}
