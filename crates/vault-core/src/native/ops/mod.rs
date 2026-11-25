//! Command handlers grouped like `contract/commands.json` (`group`): one file per group.
//! Groups with richer state keep their handlers next to that state (`relay`, `history`,
//! `passkeys`, `recovery`, `devices`, `capabilities`).
mod backup;
mod categories;
mod items;
mod notes;
mod sharing;
pub(in crate::native) mod tools;
mod vault;
