use core_foundation::{base::{CFType, TCFType}, boolean::CFBoolean, data::CFData, dictionary::CFDictionary, string::CFString};
use objc2::{class, msg_send, rc::Retained, runtime::{AnyObject, Bool}};
use objc2_foundation::{NSNotification, NSNotificationCenter, NSString};
use security_framework_sys::{access_control::*, item::*, keychain_item::*};
use sha2::{Digest, Sha256};
use std::{path::Path, ptr, sync::{Once, atomic::{AtomicU8, Ordering}}};
use zeroize::Zeroizing;

const SERVICE: &str = "com.securepass.vault.nshpreview.biometric";
#[link(name = "LocalAuthentication", kind = "framework")]
unsafe extern "C" {}
#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" { fn CGEventSourceSecondsSinceLastEventType(state: i32, event: u32) -> f64; }

fn context() -> Retained<AnyObject> { unsafe { msg_send![class!(LAContext), new] } }
pub fn available() -> bool {
    let context = context();
    let ok: Bool = unsafe { msg_send![&*context, canEvaluatePolicy: 1isize, error: ptr::null_mut::<*mut AnyObject>()] };
    ok.as_bool()
}
fn account(path: &Path) -> String {
    // Existing vaults are canonicalized so path aliases share one preview credential.
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    format!("{:x}", Sha256::digest(path.to_string_lossy().as_bytes()))
}
unsafe fn cf(raw: *const std::ffi::c_void) -> CFType { unsafe { CFType::wrap_under_get_rule(raw) } }
fn query(path: &Path) -> Vec<(CFType, CFType)> { unsafe { vec![
    (cf(kSecClass.cast()), cf(kSecClassGenericPassword.cast())),
    (cf(kSecAttrService.cast()), CFString::new(SERVICE).as_CFType()),
    (cf(kSecAttrAccount.cast()), CFString::new(&account(path)).as_CFType()),
    (cf(kSecUseDataProtectionKeychain.cast()), CFBoolean::true_value().as_CFType()),
] } }
fn status(code: i32) -> Result<(), String> { if code == 0 { Ok(()) } else { Err(format!("Keychain:{code}")) } }
pub fn enabled(path: &Path) -> Result<bool, String> {
    let mut q = query(path);
    unsafe {
        // Metadata only; never display authentication UI while rendering settings.
        q.push((cf(kSecReturnAttributes.cast()), CFBoolean::true_value().as_CFType()));
        let ctx = context();
        let _: () = msg_send![&*ctx, setInteractionNotAllowed: true];
        q.push((cf(kSecUseAuthenticationContext.cast()), cf(Retained::as_ptr(&ctx).cast())));
        let code = SecItemCopyMatching(CFDictionary::from_CFType_pairs(&q).as_concrete_TypeRef(), ptr::null_mut());
        match code { 0 | -25308 => Ok(true), -25300 => Ok(false), _ => { status(code)?; Ok(false) } }
    }
}
pub fn enroll(path: &Path, key: &[u8]) -> Result<(), String> {
    if key.len() != 32 { return Err("Authentication".into()); }
    if !available() { return Err("BiometricUnavailable".into()); }
    unsafe {
        let access = SecAccessControlCreateWithFlags(ptr::null(), kSecAttrAccessibleWhenUnlockedThisDeviceOnly.cast(), kSecAccessControlBiometryCurrentSet, ptr::null_mut());
        if access.is_null() { return Err("BiometricUnavailable".into()); }
        let access = CFType::wrap_under_create_rule(access.cast());
        let data = CFData::from_buffer(key);
        let attrs = vec![(cf(kSecAttrAccessControl.cast()), access), (cf(kSecValueData.cast()), data.as_CFType())];
        let mut q = query(path);
        q.extend(attrs.clone());
        q.push((cf(kSecAttrSynchronizable.cast()), CFBoolean::false_value().as_CFType()));
        let code = SecItemAdd(CFDictionary::from_CFType_pairs(&q).as_concrete_TypeRef(), ptr::null_mut());
        status(if code == -25299 { SecItemUpdate(CFDictionary::from_CFType_pairs(&query(path)).as_concrete_TypeRef(), CFDictionary::from_CFType_pairs(&attrs).as_concrete_TypeRef()) } else { code })
    }
}
pub fn remove(path: &Path) -> Result<(), String> {
    let code = unsafe { SecItemDelete(CFDictionary::from_CFType_pairs(&query(path)).as_concrete_TypeRef()) };
    if code == -25300 { Ok(()) } else { status(code) }
}
pub fn retrieve(path: &Path) -> Result<Zeroizing<Vec<u8>>, String> {
    unsafe {
        let ctx = context();
        let _: () = msg_send![&*ctx, setLocalizedReason: &*NSString::from_str("解锁 PasswordVault 预览版")];
        let _: () = msg_send![&*ctx, setTouchIDAuthenticationAllowableReuseDuration: 0.0f64];
        let mut q = query(path);
        q.push((cf(kSecUseAuthenticationContext.cast()), cf(Retained::as_ptr(&ctx).cast())));
        q.push((cf(kSecReturnData.cast()), CFBoolean::true_value().as_CFType()));
        let mut result = ptr::null();
        status(SecItemCopyMatching(CFDictionary::from_CFType_pairs(&q).as_concrete_TypeRef(), &mut result))?;
        if result.is_null() { return Err("Authentication".into()); }
        let value = CFType::wrap_under_create_rule(result);
        let data = value.downcast::<CFData>().ok_or("Authentication")?;
        if data.len() != 32 { return Err("Authentication".into()); }
        Ok(Zeroizing::new(data.bytes().to_vec()))
    }
}

static START: Once = Once::new();
static EVENTS: AtomicU8 = AtomicU8::new(0);
fn observe(center: &NSNotificationCenter, name: &str, bit: u8) {
    let block = block2::RcBlock::new(move |_: std::ptr::NonNull<NSNotification>| { EVENTS.fetch_or(bit, Ordering::SeqCst); });
    let token = unsafe { center.addObserverForName_object_queue_usingBlock(Some(&NSString::from_str(name)), None, None, &block) };
    // One observer per process; retained until process exit, with no JS callbacks.
    std::mem::forget(token);
}
pub fn poll() -> String {
    START.call_once(|| unsafe {
        let workspace: Retained<AnyObject> = msg_send![class!(NSWorkspace), sharedWorkspace];
        let center: Retained<NSNotificationCenter> = msg_send![&*workspace, notificationCenter];
        observe(&center, "NSWorkspaceWillSleepNotification", 1);
        observe(&center, "NSWorkspaceSessionDidResignActiveNotification", 2);
        let distributed: Retained<NSNotificationCenter> = msg_send![class!(NSDistributedNotificationCenter), defaultCenter];
        observe(&distributed, "com.apple.screenIsLocked", 4);
        observe(&distributed, "com.apple.screensaver.didstart", 8);
    });
    let idle = unsafe { CGEventSourceSecondsSinceLastEventType(0, u32::MAX) };
    serde_json::json!({"events": EVENTS.swap(0, Ordering::SeqCst), "idleSeconds": if idle.is_finite() && idle >= 0.0 { Some(idle) } else { None }}).to_string()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn preview_namespace_and_event_drain() {
        assert_ne!(SERVICE, "com.securepass.vault.macos.biometric");
        assert_ne!(account(Path::new("/tmp/vault-a")), account(Path::new("/tmp/vault-b")));
        EVENTS.store(0, Ordering::SeqCst);
        let center = NSNotificationCenter::new();
        observe(&center, "preview.test.sleep", 1);
        observe(&center, "preview.test.screen", 4);
        unsafe {
            center.postNotificationName_object(&NSString::from_str("preview.test.sleep"), None);
            center.postNotificationName_object(&NSString::from_str("preview.test.screen"), None);
        }
        assert_eq!(EVENTS.swap(0, Ordering::SeqCst), 5);
        assert_eq!(EVENTS.swap(0, Ordering::SeqCst), 0);
    }
}
