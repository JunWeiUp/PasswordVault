use super::*;

impl DiskVault {
    pub(super) fn devices_command(&mut self, request: &Value) -> Result<Value> {
        let format = self.open()?.document.format_version;
        if request["op"] == "devices-status" {
            return Ok(
                json!({"enabled":format >= DEVICES_FORMAT,"formatVersion":format,"syncBlocked":format >= DEVICES_FORMAT}),
            );
        }
        if request["op"] == "devices-file-read" {
            let open = self.open()?;
            let owner = request["id"].as_str().ok_or(VaultError::InvalidData)?;
            let id = request["attachmentId"]
                .as_str()
                .ok_or(VaultError::InvalidData)?;
            let item = open
                .document
                .items
                .iter()
                .find(|i| i["id"] == owner && i["type"] == "device" && i["isDeleted"] != true)
                .ok_or(VaultError::InvalidData)?;
            if !item["device"]["files"]
                .as_array()
                .ok_or(VaultError::InvalidData)?
                .iter()
                .any(|f| f["attachmentId"] == id)
            {
                return Err(VaultError::InvalidData);
            }
            let meta = notes::metas(&open.connection)?
                .into_iter()
                .find(|m| m.id == id && m.note_id == owner && m.size <= 262144)
                .ok_or(VaultError::InvalidData)?;
            let bytes = notes::read(&open.connection, &open.root, &open.header.vault_id, &meta)?;
            let text = std::str::from_utf8(&bytes).map_err(|_| VaultError::InvalidData)?;
            return Ok(json!({"text":text}));
        }
        if request["op"] != "devices-enable" || request["confirm"] != true {
            return Err(VaultError::InvalidData);
        }
        let password = request["currentPassword"]
            .as_str()
            .ok_or(VaultError::InvalidData)?;
        self.open()?.header.unlock(password)?;
        if self.open()?.document.settings["activePeerLibrary"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
        {
            return Err(VaultError::Unsupported);
        }
        if format >= DEVICES_FORMAT {
            return Ok(json!({"ok":true}));
        }
        let destination = self.directory.join("before-devices-format7");
        // An existing path is not evidence of a completed snapshot. Fail safely on collisions.
        if destination.exists() {
            return Err(VaultError::Storage);
        }
        let temp = storage(
            tempfile::Builder::new()
                .prefix(".devices-backup-")
                .tempdir_in(&self.directory),
        )?;
        protect_dir(temp.path())?;
        for name in ["header.json", "vault.sqlite", "recovery.json"] {
            let bytes = match fs::read(self.directory.join(name)) {
                Ok(bytes) => bytes,
                Err(e) if name == "recovery.json" && e.kind() == std::io::ErrorKind::NotFound => {
                    continue
                }
                Err(_) => return Err(VaultError::Storage),
            };
            atomic_write(&temp.path().join(name), &bytes)?;
        }
        storage(fs::rename(temp.path(), &destination))?;
        storage(crate::native_file_ops::sync_directory(&self.directory))?;
        self.mutate(|doc| {
            if doc.format_version == 5 {
                doc.settings["entryHistoryEnabled"] = json!(true);
            }
            doc.format_version = DEVICES_FORMAT;
            doc.settings["devicesEnabled"] = json!(true);
            Ok(json!({"ok":true}))
        })
    }
}
