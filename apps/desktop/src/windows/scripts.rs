//! Mac terminal handoff is not portable. Fail closed until Windows handoff exists.
use nsh_core::prelude::*;
use crate::Vault;
/// Disabled terminal integration; script contents are never executed.
#[module]
pub struct Scripts;
#[module]
impl Scripts {
    /// Windows terminal handoff is not enabled in this preview.
    pub async fn terminals(_vault: Instance<Vault>) -> Result<String, String> { Ok(r#"{"selected":"","options":[]}"#.into()) }
    /// Windows terminal handoff is not enabled in this preview.
    pub async fn select_terminal(_vault: Instance<Vault>, _id: String) -> Result<String, String> { Err("Unsupported".into()) }
    /// Windows terminal handoff is not enabled in this preview.
    pub async fn choose_terminal(_vault: Instance<Vault>) -> Result<String, String> { Err("Unsupported".into()) }
    /// Windows terminal handoff is not enabled in this preview.
    pub async fn run(_vault: Instance<Vault>, _name: String, source: String) -> Result<String, String> {
        let _source = zeroize::Zeroizing::new(source);
        Err("Windows 预览版暂不支持终端脚本运行".into())
    }
}
