//! Unified cross-platform `Scripts` NSH module contract.
//!
//! Keeping one `#[module]` definition shared by macOS and Windows prevents
//! platform stub drift while macOS terminal handoff remains isolated in `script_runner`.

use crate::Vault;
use nsh_core::prelude::*;

/// Terminal script handoff preferences and execution.
#[module]
pub struct Scripts;

#[module]
impl Scripts {
    /// Returns installed terminal choices and the persistent preference.
    pub async fn terminals(vault: Instance<Vault>) -> Result<String, String> {
        #[cfg(target_os = "macos")]
        {
            crate::script_runner::Scripts::terminals(vault).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = vault;
            Ok(r#"{"selected":"","options":[]}"#.into())
        }
    }

    /// Remembers an installed terminal for future launches.
    pub async fn select_terminal(vault: Instance<Vault>, id: String) -> Result<String, String> {
        #[cfg(target_os = "macos")]
        {
            crate::script_runner::Scripts::select_terminal(vault, id).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (vault, id);
            Err("Unsupported".into())
        }
    }

    /// Selects a supported terminal bundle in a nonstandard location.
    pub async fn choose_terminal(vault: Instance<Vault>) -> Result<String, String> {
        #[cfg(target_os = "macos")]
        {
            crate::script_runner::Scripts::choose_terminal(vault).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = vault;
            Err("Unsupported".into())
        }
    }

    /// Opens the chosen terminal and executes source interactively; no in-app runner.
    pub async fn run(
        vault: Instance<Vault>,
        name: String,
        source: String,
    ) -> Result<String, String> {
        #[cfg(target_os = "macos")]
        {
            crate::script_runner::Scripts::run(vault, name, source).await
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (vault, name);
            let _source = zeroize::Zeroizing::new(source);
            Err("Windows 预览版暂不支持终端脚本运行".into())
        }
    }
}
