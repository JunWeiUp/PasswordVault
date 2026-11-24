//! macOS code identity and non-interactive legacy Keychain access.
use core_foundation::{
    base::{CFType, TCFType},
    boolean::CFBoolean,
    data::CFData,
    dictionary::CFDictionary,
    string::CFString,
    url::CFURL,
};
use security_framework_sys::{code_signing::*, item::*, keychain_item::*};
use std::{ffi::c_void, path::Path, ptr};
use zeroize::Zeroizing;
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecCodeCopyStaticCode(code: SecCodeRef, flags: u32, out: *mut SecStaticCodeRef) -> i32;
    fn SecCodeCopySigningInformation(
        code: SecStaticCodeRef,
        flags: u32,
        out: *mut core_foundation::dictionary::CFDictionaryRef,
    ) -> i32;
    fn SecCodeCopyDesignatedRequirement(
        code: SecStaticCodeRef,
        flags: u32,
        out: *mut SecRequirementRef,
    ) -> i32;
    fn SecRequirementCopyData(
        requirement: SecRequirementRef,
        flags: u32,
        out: *mut core_foundation::data::CFDataRef,
    ) -> i32;
    static kSecUseAuthenticationUIFail: core_foundation::string::CFStringRef;
    static kSecCodeInfoUnique: core_foundation::string::CFStringRef;
    static kSecCodeInfoCertificates: core_foundation::string::CFStringRef;
    fn SecKeychainSetUserInteractionAllowed(allowed: u8) -> i32;
}
unsafe fn cf(raw: *const c_void) -> CFType {
    unsafe { CFType::wrap_under_get_rule(raw) }
}
unsafe fn hash(code: SecStaticCodeRef) -> Option<Vec<u8>> {
    unsafe {
        let mut info = ptr::null();
        if SecCodeCopySigningInformation(code, 2, &mut info) != 0 {
            return None;
        }
        let info: CFDictionary<CFType, CFType> = CFDictionary::wrap_under_create_rule(info);
        info.find(&cf(kSecCodeInfoUnique.cast()))?
            .downcast::<CFData>()
            .map(|d| d.bytes().to_vec())
    }
}
pub fn code_hash(path: &Path) -> Option<Vec<u8>> {
    unsafe {
        let url = CFURL::from_path(path, false)?;
        let mut code = ptr::null_mut();
        if SecStaticCodeCreateWithPath(url.as_concrete_TypeRef(), 0, &mut code) != 0 {
            return None;
        }
        let _owner = CFType::wrap_under_create_rule(code.cast());
        if SecStaticCodeCheckValidity(code, 0, ptr::null_mut()) != 0 {
            return None;
        }
        hash(code)
    }
}
/// Validated signing identity matching the login-Keychain default ACL:
/// certificate-signed helpers use their designated requirement (stable across
/// rebuilds with the same certificate), while ad-hoc helpers always use their
/// per-binary CDHash and ignore unauthenticated custom requirements.
#[allow(dead_code)]
pub fn signing_identity(path: &Path) -> Option<Vec<u8>> {
    unsafe {
        let url = CFURL::from_path(path, false)?;
        let mut code = ptr::null_mut();
        if SecStaticCodeCreateWithPath(url.as_concrete_TypeRef(), 0, &mut code) != 0 {
            return None;
        }
        let _owner = CFType::wrap_under_create_rule(code.cast());
        if SecStaticCodeCheckValidity(code, kSecCSStrictValidate, ptr::null_mut()) != 0 {
            return None;
        }
        let mut info = ptr::null();
        if SecCodeCopySigningInformation(code, 2, &mut info) != 0 || info.is_null() {
            return None;
        }
        let info: CFDictionary<CFType, CFType> = CFDictionary::wrap_under_create_rule(info);
        let has_cert = info
            .find(&cf(kSecCodeInfoCertificates.cast()))
            .and_then(|v| v.downcast::<core_foundation::array::CFArray>())
            .is_some_and(|certs| !certs.is_empty());
        if !has_cert {
            return info
                .find(&cf(kSecCodeInfoUnique.cast()))?
                .downcast::<CFData>()
                .map(|d| d.bytes().to_vec());
        }
        let mut req = ptr::null_mut();
        if SecCodeCopyDesignatedRequirement(code, 0, &mut req) != 0 || req.is_null() {
            return None;
        }
        let _req = CFType::wrap_under_create_rule(req.cast());
        let mut data = ptr::null();
        if SecRequirementCopyData(req, 0, &mut data) != 0 || data.is_null() {
            return None;
        }
        Some(CFData::wrap_under_create_rule(data).bytes().to_vec())
    }
}
/// Full static validation reads the whole executable. Every IPC connection checks
/// its peer, so cache the expected file's validated identity until the file itself
/// changes (device, inode, size or modification time). The connecting process is
/// still validated dynamically on every connection.
fn cached_code_hash(path: &Path) -> Option<Vec<u8>> {
    use std::os::unix::fs::MetadataExt;
    type Key = (u64, u64, u64, i64, i64);
    static CACHE: std::sync::Mutex<Option<(std::path::PathBuf, Key, Vec<u8>)>> =
        std::sync::Mutex::new(None);
    let meta = std::fs::metadata(path).ok()?;
    let key: Key = (
        meta.dev(),
        meta.ino(),
        meta.size(),
        meta.mtime(),
        meta.mtime_nsec(),
    );
    if let Ok(cache) = CACHE.lock() {
        if let Some((cached, k, hash)) = cache.as_ref() {
            if cached == path && *k == key {
                return Some(hash.clone());
            }
        }
    }
    let hash = code_hash(path)?;
    if let Ok(mut cache) = CACHE.lock() {
        *cache = Some((path.to_path_buf(), key, hash.clone()));
    }
    Some(hash)
}
pub fn peer(fd: i32, expected: &Path) -> bool {
    unsafe {
        let mut audit = [0u8; 32];
        let mut length = 32u32;
        if libc::getsockopt(fd, 0, 6, audit.as_mut_ptr().cast(), &mut length) != 0 || length != 32 {
            return false;
        }
        let attrs = CFDictionary::from_CFType_pairs(&[(
            cf(kSecGuestAttributeAudit.cast()),
            CFData::from_buffer(&audit).as_CFType(),
        )]);
        let mut guest = ptr::null_mut();
        if SecCodeCopyGuestWithAttributes(
            ptr::null_mut(),
            attrs.as_concrete_TypeRef(),
            0,
            &mut guest,
        ) != 0
        {
            return false;
        }
        let _guest = CFType::wrap_under_create_rule(guest.cast());
        if SecCodeCheckValidity(guest, 0, ptr::null_mut()) != 0 {
            return false;
        }
        let mut actual = ptr::null_mut();
        if SecCodeCopyStaticCode(guest, 0, &mut actual) != 0 {
            return false;
        }
        let _actual = CFType::wrap_under_create_rule(actual.cast());
        matches!((hash(actual), cached_code_hash(expected)), (Some(a),Some(b)) if a == b)
    }
}
fn query(service: &str, account: &str) -> Vec<(CFType, CFType)> {
    unsafe {
        vec![
            (cf(kSecClass.cast()), cf(kSecClassGenericPassword.cast())),
            (
                cf(kSecAttrService.cast()),
                CFString::new(service).as_CFType(),
            ),
            (
                cf(kSecAttrAccount.cast()),
                CFString::new(account).as_CFType(),
            ),
            (
                cf(kSecUseAuthenticationUI.cast()),
                cf(kSecUseAuthenticationUIFail.cast()),
            ),
        ]
    }
}
pub fn keychain(
    service: &str,
    account: &str,
    write: Option<Option<&[u8]>>,
) -> Result<Zeroizing<Vec<u8>>, String> {
    unsafe {
        SecKeychainSetUserInteractionAllowed(0);
        let q = query(service, account);
        let dict = CFDictionary::from_CFType_pairs(&q);
        let code = match write {
            Some(None) => {
                let c = SecItemDelete(dict.as_concrete_TypeRef());
                if c == -25300 { 0 } else { c }
            }
            Some(Some(bytes)) => {
                let attrs = [(
                    cf(kSecValueData.cast()),
                    CFData::from_buffer(bytes).as_CFType(),
                )];
                let mut add = q;
                add.retain(|(k, _)| *k != cf(kSecUseAuthenticationUI.cast()));
                add.extend(attrs.clone());
                // The default login-Keychain ACL trusts only the creating executable.
                let c = SecItemAdd(
                    CFDictionary::from_CFType_pairs(&add).as_concrete_TypeRef(),
                    ptr::null_mut(),
                );
                if c == -25299 {
                    SecItemUpdate(
                        dict.as_concrete_TypeRef(),
                        CFDictionary::from_CFType_pairs(&attrs).as_concrete_TypeRef(),
                    )
                } else {
                    c
                }
            }
            None => {
                let mut q = q;
                q.push((
                    cf(kSecReturnData.cast()),
                    CFBoolean::true_value().as_CFType(),
                ));
                let mut result = ptr::null();
                let c = SecItemCopyMatching(
                    CFDictionary::from_CFType_pairs(&q).as_concrete_TypeRef(),
                    &mut result,
                );
                if c != 0 || result.is_null() {
                    return Err("sync-authorization".into());
                }
                let value = CFType::wrap_under_create_rule(result);
                return Ok(Zeroizing::new(
                    value
                        .downcast::<CFData>()
                        .ok_or("sync-authorization")?
                        .bytes()
                        .to_vec(),
                ));
            }
        };
        if code == 0 {
            Ok(Zeroizing::new(Vec::new()))
        } else {
            Err("sync-keychain".into())
        }
    }
}
pub fn parent(expected: &Path) -> bool {
    unsafe {
        use core_foundation::number::CFNumber;
        let attrs = CFDictionary::from_CFType_pairs(&[(
            cf(kSecGuestAttributePid.cast()),
            CFNumber::from(libc::getppid()).as_CFType(),
        )]);
        let mut guest = ptr::null_mut();
        if SecCodeCopyGuestWithAttributes(
            ptr::null_mut(),
            attrs.as_concrete_TypeRef(),
            0,
            &mut guest,
        ) != 0
        {
            return false;
        }
        let _guest = CFType::wrap_under_create_rule(guest.cast());
        if SecCodeCheckValidity(guest, 0, ptr::null_mut()) != 0 {
            return false;
        }
        let mut actual = ptr::null_mut();
        if SecCodeCopyStaticCode(guest, 0, &mut actual) != 0 {
            return false;
        }
        let _actual = CFType::wrap_under_create_rule(actual.cast());
        matches!((hash(actual),cached_code_hash(expected)),(Some(a),Some(b)) if a==b)
    }
}
