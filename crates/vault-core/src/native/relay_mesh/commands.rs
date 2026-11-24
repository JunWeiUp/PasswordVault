use super::*;

impl DiskVault {
    pub(in crate::native) fn mesh_command(&mut self, request: &Value) -> Result<Value> {
        let vault_dir = self.directory.clone();
        let op = string(request, "op")?;
        if op == "relay-mesh-init" {
            return self.mesh_init(request);
        }
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Err(VaultError::Unsupported);
        }
        let mut mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        if !mesh.resent_after_causal_fix {
            // One complete resend to every peer restores records an affected build dropped;
            // records the peer already holds are recognised and change nothing.
            mesh.acked.clear();
            mesh.ack_sent.clear();
            mesh.resent_after_causal_fix = true;
            store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
        }
        match op {
            "relay-mesh-peers" => {
                let peers: BTreeSet<String> = serde_json::from_value(request["peers"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                if peers.len() > 256 || !peers.iter().all(|p| valid_name(p)) {
                    return Err(VaultError::InvalidData);
                }
                let peers: BTreeSet<String> =
                    peers.into_iter().filter(|p| p != &mesh.device).collect();
                // A removed member stops receiving immediately; if re-added later it
                // starts from a complete resend.
                for gone in mesh.peers.difference(&peers).cloned().collect::<Vec<_>>() {
                    mesh.acked.remove(&gone);
                    mesh.ack_sent.remove(&gone);
                }
                mesh.peers = peers;
                store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
                Ok(json!({"ok":true,"peers":mesh.peers}))
            }
            "relay-mesh-export" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let acked = *mesh.acked.get(peer).unwrap_or(&0);
                let current = mesh_records(&open.document);
                let mut records = serde_json::Map::new();
                let mut values = serde_json::Map::new();
                for (key, meta) in mesh.meta.iter().filter(|(_, m)| m.seq > acked) {
                    let mut value = current.get(key).cloned().unwrap_or(Value::Null);
                    if !value.is_null() && key.starts_with("item:") {
                        note_bodies::hydrate_item(
                            &open.connection,
                            &open.root,
                            &open.header.vault_id,
                            &mut value,
                        )?;
                    }
                    values.insert(key.clone(), value.clone());
                    records.insert(
                        key.clone(),
                        json!({"value":value,"stamp":meta.stamp,"vv":versions(&meta.stamp, &meta.vv)}),
                    );
                }
                let ack = *mesh.received.get(peer).unwrap_or(&0);
                if records.is_empty() && mesh.ack_sent.get(peer) == Some(&ack) {
                    return Ok(json!({"packet":null}));
                }
                let (files, remote_files) = attachments_split(
                    &vault_dir,
                    open,
                    &json!({"records":values}),
                    INLINE_ATTACHMENT_LIMIT,
                    &mesh.device,
                )?;
                mesh.ack_sent.insert(peer.into(), ack);
                store(&open.connection, &open.root, &open.header.vault_id, &mesh)?;
                let mut packet = json!({
                    "version":PACKET_VERSION,"kind":"mesh","group":mesh.group,
                    "from":mesh.device,"to":peer,"formatVersion":open.document.format_version,
                    "upto":mesh.seq,"ack":ack,"records":records,"files":files
                });
                if remote_files.as_array().is_some_and(|a| !a.is_empty()) {
                    packet["remoteFiles"] = remote_files;
                }
                Ok(json!({"packet": packet}))
            }
            "relay-mesh-receive" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let packet = &request["packet"];
                if packet["version"] != PACKET_VERSION || packet["kind"] != "mesh" {
                    return Err(VaultError::Unsupported);
                }
                if packet["group"] != mesh.group.as_str()
                    || packet["from"] != peer
                    || packet["to"] != mesh.device.as_str()
                {
                    return Err(VaultError::Authentication);
                }
                let format = packet["formatVersion"]
                    .as_u64()
                    .filter(|v| (2..=u64::from(crate::devices::DEVICES_FORMAT)).contains(v))
                    .ok_or(VaultError::Unsupported)? as u32;
                let upto = packet["upto"].as_u64().ok_or(VaultError::InvalidData)?;
                let ack = packet["ack"].as_u64().ok_or(VaultError::InvalidData)?;
                let incoming = packet["records"]
                    .as_object()
                    .ok_or(VaultError::InvalidData)?;
                if incoming.len() > 100_001 {
                    return Err(VaultError::InvalidData);
                }
                let now = now_ms();
                let mut next = open.document.clone();
                next.format_version = next.format_version.max(format);
                let mut working = mesh_records(&next);
                let original = working.clone();
                let tx = storage(open.connection.transaction())?;
                receive_files(
                    &vault_dir,
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &packet["files"],
                )?;
                receive_remote_files(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    peer,
                    &packet["remoteFiles"],
                )?;
                let mut changed = false;
                let mut applied = 0usize;
                // One invalid record must not stall the whole sync forever: it is skipped
                // (never applied) and reported by key, the rest of the packet still applies.
                let mut rejected: Vec<String> = Vec::new();
                for (key, record) in incoming {
                    let checked = (|| -> Result<(Stamp, Value, Versions)> {
                        if !valid_key(key) {
                            return Err(VaultError::InvalidData);
                        }
                        let stamp: Stamp = serde_json::from_value(record["stamp"].clone())
                            .map_err(|_| VaultError::InvalidData)?;
                        if stamp.0 > now.saturating_add(MAX_FUTURE_MS) || stamp.2.len() > 128 {
                            return Err(VaultError::InvalidData);
                        }
                        let vv: Versions = match record.get("vv") {
                            None | Some(Value::Null) => Versions::new(),
                            Some(v) => serde_json::from_value(v.clone())
                                .map_err(|_| VaultError::InvalidData)?,
                        };
                        if vv.len() > 64
                            || vv.iter().any(|(d, (ms, _))| {
                                d.is_empty()
                                    || d.len() > 128
                                    || *ms > now.saturating_add(MAX_FUTURE_MS)
                            })
                        {
                            return Err(VaultError::InvalidData);
                        }
                        let value = record["value"].clone();
                        if key.starts_with("category:")
                            && !(value.is_null() || value == json!(true))
                        {
                            return Err(VaultError::InvalidData);
                        }
                        if key.starts_with("item:") && !value.is_null() {
                            if value["id"].as_str() != key.strip_prefix("item:") {
                                return Err(VaultError::InvalidData);
                            }
                            let mut proposed = Document {
                                format_version: next.format_version,
                                ..Document::default()
                            };
                            proposed.items.push(value.clone());
                            let proposed = Document::parse(
                                &serde_json::to_vec(&proposed)
                                    .map_err(|_| VaultError::InvalidData)?,
                            )?;
                            validate_files(&tx, &proposed)?;
                        }
                        Ok((stamp, value, vv))
                    })();
                    let (stamp, value, incoming_vv) = match checked {
                        Ok(checked) => checked,
                        Err(VaultError::InvalidData | VaultError::Unsupported) => {
                            if rejected.len() < 64 {
                                rejected.push(key.chars().take(96).collect());
                            }
                            continue;
                        }
                        Err(other) => return Err(other),
                    };
                    if stamp.0 > now.saturating_add(SKEW_NOTICE_MS) {
                        mesh.skew = true;
                    }
                    let mut local = working.get(key).cloned().unwrap_or(Value::Null);
                    if !local.is_null() && key.starts_with("item:") {
                        note_bodies::hydrate_item(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            &mut local,
                        )?;
                    }
                    // Existing legacy shared records never acquire new editing permission.
                    if !local.is_null()
                        && local != value
                        && (!local["sharedVaultId"].as_str().unwrap_or("").is_empty()
                            || !value["sharedVaultId"].as_str().unwrap_or("").is_empty())
                    {
                        continue;
                    }
                    let local_stamp = mesh
                        .meta
                        .get(key)
                        .map(|m| m.stamp.clone())
                        .unwrap_or_default();
                    let local_vv = mesh
                        .meta
                        .get(key)
                        .map(|m| versions(&m.stamp, &m.vv))
                        .unwrap_or_default();
                    let incoming_vv = versions(&stamp, &incoming_vv);
                    // Causality first: an edit made on top of our value replaces it, and one we
                    // already include is stale. Only edits neither side has seen are concurrent.
                    // Records without causal history (migrated legacy hub records carry no
                    // device) fall back to the stamp comparison below.
                    let causal = !incoming_vv.is_empty();
                    let newer =
                        causal && includes(&incoming_vv, &local_vv) && incoming_vv != local_vv;
                    let stale = causal && !newer && includes(&local_vv, &incoming_vv);
                    let merged_vv = join(&local_vv, &incoming_vv);
                    mesh.observe(&stamp);
                    let wins = newer
                        || (!stale
                            && (stamp > local_stamp
                                || (stamp == local_stamp
                                    && local != value
                                    && value_digest(&value) > value_digest(&local))));

                    let concurrent_note = !newer
                        && !stale
                        && key.starts_with("item:")
                        && !local.is_null()
                        && !value.is_null()
                        && local != value
                        && local["type"] == "secureNote"
                        && value["type"] == "secureNote"
                        && local["isDeleted"] != true
                        && value["isDeleted"] != true
                        && local_stamp.0 > 0
                        && stamp.0 > 0
                        && !local_stamp.2.is_empty()
                        && !stamp.2.is_empty()
                        && local_stamp.2 != stamp.2;

                    if concurrent_note {
                        let note_id = key["item:".len()..].to_string();
                        let (winner, loser, loser_dev, winning_stamp) = if wins {
                            (&value, &local, mesh.device.as_str(), stamp.clone())
                        } else {
                            (&local, &value, peer, local_stamp.clone())
                        };
                        let base_item =
                            history::page(&tx, &open.root, &open.header.vault_id, &note_id, 0, 8)
                                .ok()
                                .and_then(|(_, revs)| {
                                    revs.into_iter().map(|r| r.item).find(|v| {
                                        v["note"] != winner["note"] && v["note"] != loser["note"]
                                    })
                                });
                        let merged = merge_concurrent_note(base_item.as_ref(), winner, loser);
                        if merged.has_overlap {
                            let rev_id = new_id();
                            history::write(
                                &tx,
                                &open.root,
                                &open.header.vault_id,
                                &history::Revision {
                                    id: rev_id.clone(),
                                    item_id: note_id.clone(),
                                    captured_at: if wins { local_stamp.0 } else { stamp.0 },
                                    item: loser.clone(),
                                    actor_type: Some("sync".into()),
                                    actor: Some(format!("并行分支 · {loser_dev}")),
                                    summary: Some(format!(
                                        "并发编辑保留分支（{}）",
                                        merged.conflict_section
                                    )),
                                    milestone: None,
                                },
                            )?;
                            mesh.note_conflicts.insert(
                                note_id.clone(),
                                NoteConflict {
                                    note_id,
                                    local_device: mesh.device.clone(),
                                    remote_device: peer.to_string(),
                                    revision_id: rev_id,
                                    captured_at: now,
                                    section: merged.conflict_section,
                                    auto_merged: merged.auto_merged,
                                    asset_guard: merged.asset_guard,
                                    retention_days: 30,
                                },
                            );
                        }
                        if merged.item != local {
                            working.insert(key.clone(), merged.item);
                            let next_stamp = if wins {
                                winning_stamp
                            } else {
                                mesh.local_stamp()
                            };
                            let seq = mesh.bump()?;
                            let vv = versions(&next_stamp, &merged_vv);
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp: next_stamp,
                                    seq,
                                    vv,
                                },
                            );
                            changed = true;
                            applied += 1;
                        } else if wins {
                            let seq = mesh.bump()?;
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp: winning_stamp,
                                    seq,
                                    vv: merged_vv.clone(),
                                },
                            );
                        }
                    } else if wins {
                        if local != value {
                            let deleted = value.is_null();
                            if deleted {
                                working.remove(key);
                            } else {
                                working.insert(key.clone(), value);
                            }
                            // A deletion, or an edit already including our side (e.g. the peer
                            // resolved the same parallel branch), settles any branch here.
                            if deleted || newer {
                                if let Some(id) = key.strip_prefix("item:") {
                                    mesh.note_conflicts.remove(id);
                                }
                            }
                            let seq = mesh.bump()?;
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp,
                                    seq,
                                    vv: merged_vv.clone(),
                                },
                            );
                            changed = true;
                            applied += 1;
                        } else if let Some(meta) = mesh.meta.get_mut(key) {
                            meta.stamp = stamp;
                            meta.vv = merged_vv.clone();
                            if newer {
                                if let Some(id) = key.strip_prefix("item:") {
                                    mesh.note_conflicts.remove(id);
                                }
                            }
                        } else {
                            let seq = mesh.bump()?;
                            mesh.meta.insert(
                                key.clone(),
                                Meta {
                                    stamp,
                                    seq,
                                    vv: merged_vv.clone(),
                                },
                            );
                        }
                    } else if let (Some(meta), false) = (mesh.meta.get_mut(key), stale) {
                        // Our value stays (it has the later stamp) and now accounts for theirs.
                        meta.vv = merged_vv.clone();
                        if local != value && !value.is_null() && key.starts_with("item:") {
                            // Keep the older incoming edit recoverable from entry history.
                            history::write(
                                &tx,
                                &open.root,
                                &open.header.vault_id,
                                &history::Revision::plain(
                                    new_id(),
                                    key["item:".len()..].to_string(),
                                    stamp.0,
                                    value,
                                ),
                            )?;
                        }
                    }
                }
                let acked = mesh.acked.entry(peer.into()).or_default();
                *acked = (*acked).max(ack.min(mesh.seq));
                let received = mesh.received.entry(peer.into()).or_default();
                *received = (*received).max(upto);
                if !incoming.is_empty() {
                    mesh.ack_sent.remove(peer);
                }
                mesh.ensure_digests();
                if changed {
                    install_mesh(&mut next, &working)?;
                    // Validate attachments only for items this packet changed (including merged
                    // concurrent notes). A pre-existing local item with a dangling attachment
                    // reference must not block every future sync.
                    let changed_items = Document {
                        format_version: next.format_version,
                        items: working
                            .iter()
                            .filter(|(key, value)| {
                                key.starts_with("item:")
                                    && !value.is_null()
                                    && original.get(*key) != Some(*value)
                            })
                            .map(|(_, value)| value.clone())
                            .collect(),
                        ..Document::default()
                    };
                    validate_files(&tx, &changed_items)?;
                    let persisted =
                        note_bodies::sync_and_strip(&tx, &open.root, &open.header.vault_id, &next)?;
                    mesh.baseline_digests = mesh_digests(&persisted);
                    mesh.baseline.clear();
                    store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                    let saved = save_document_row_with_prev(
                        &tx,
                        &open.root,
                        &open.header.vault_id,
                        Some(&open.document),
                        &next,
                        None,
                    )?;
                    storage(tx.commit())?;
                    open.document = saved;
                    open.clear_hydrated_cache();
                } else {
                    store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                    if next.format_version != open.document.format_version {
                        let saved = save_document_row_with_prev(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            Some(&open.document),
                            &next,
                            None,
                        )?;
                        storage(tx.commit())?;
                        open.document = saved;
                    } else {
                        storage(tx.commit())?;
                    }
                }
                Ok(json!({
                    "ok": true,
                    "changed": changed,
                    "applied": applied,
                    "rejected": rejected,
                    "conflictCount": mesh.note_conflicts.len()
                }))
            }
            "relay-mesh-conflicts" => {
                let mut conflicts = Vec::new();
                let revs = history::read(&open.connection, &open.root, &open.header.vault_id)?;
                for cf in mesh.note_conflicts.values() {
                    let Some(mut local_item) = open
                        .document
                        .items
                        .iter()
                        .find(|i| i["id"] == cf.note_id && i["isDeleted"] != true)
                        .cloned()
                    else {
                        continue;
                    };
                    note_bodies::hydrate_item(
                        &open.connection,
                        &open.root,
                        &open.header.vault_id,
                        &mut local_item,
                    )?;
                    let remote_item = revs
                        .iter()
                        .find(|r| r.id == cf.revision_id && r.item_id == cf.note_id)
                        .map(|r| r.item.clone())
                        .unwrap_or(Value::Null);
                    conflicts.push(json!({
                        "noteId": cf.note_id,
                        "title": local_item["title"],
                        "localDevice": cf.local_device,
                        "remoteDevice": cf.remote_device,
                        "revisionId": cf.revision_id,
                        "capturedAt": cf.captured_at,
                        "section": cf.section,
                        "autoMerged": cf.auto_merged,
                        "assetGuard": cf.asset_guard,
                        "retentionDays": cf.retention_days,
                        "localItem": local_item,
                        "remoteItem": remote_item,
                    }));
                }
                Ok(json!({"conflicts": conflicts}))
            }
            "relay-mesh-resolve-conflict" => {
                let id = string(request, "id")?;
                let strategy = request["strategy"].as_str().unwrap_or("local");
                if !matches!(strategy, "local" | "remote" | "both" | "custom") {
                    return Err(VaultError::InvalidData);
                }
                let cf = mesh
                    .note_conflicts
                    .get(id)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                let mut local_item = open
                    .document
                    .items
                    .iter()
                    .find(|i| i["id"] == id)
                    .cloned()
                    .ok_or(VaultError::InvalidData)?;
                note_bodies::hydrate_item(
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &mut local_item,
                )?;
                let remote_item =
                    history::read(&open.connection, &open.root, &open.header.vault_id)?
                        .into_iter()
                        .find(|r| r.id == cf.revision_id && r.item_id == id)
                        .map(|r| r.item);
                let resolved = match strategy {
                    "local" => local_item.clone(),
                    "remote" => {
                        let mut r = remote_item.ok_or(VaultError::InvalidData)?;
                        // Preserve R9 attachment union even when picking remote branch.
                        r = merge_concurrent_note(None, &r, &local_item).item;
                        r
                    }
                    "both" => {
                        let remote = remote_item.ok_or(VaultError::InvalidData)?;
                        let mut merged = merge_concurrent_note(None, &local_item, &remote).item;
                        let a_text = local_item["note"].as_str().unwrap_or("").trim();
                        let b_text = remote["note"].as_str().unwrap_or("").trim();
                        if !b_text.is_empty() && a_text != b_text {
                            let combined = format!(
                                "{a_text}\n\n---\n### 来自并行分支（{}）\n{b_text}",
                                cf.remote_device
                            );
                            merged["note"] = json!(combined);
                            if let Some(arr) = merged["noteDocument"]["content"].as_array_mut() {
                                arr.push(json!({"type":"horizontalRule"}));
                                arr.push(json!({"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":format!("来自并行分支（{}）", cf.remote_device)}]}));
                                for line in b_text.lines().filter(|l| !l.trim().is_empty()) {
                                    arr.push(json!({"type":"paragraph","content":[{"type":"text","text":line}]}));
                                }
                            }
                        }
                        merged
                    }
                    "custom" => {
                        let custom = request
                            .get("item")
                            .cloned()
                            .ok_or(VaultError::InvalidData)?;
                        if custom["id"].as_str() != Some(id) {
                            return Err(VaultError::InvalidData);
                        }
                        custom
                    }
                    _ => return Err(VaultError::InvalidData),
                };
                let mut resolved_item = resolved;
                resolved_item["lastActor"] = json!("分支合并 · 我");
                resolved_item["lastSummary"] = json!(format!(
                    "已解决并行分支（策略：{strategy}，原分支保留 {} 天）",
                    cf.retention_days
                ));
                let mut next = open.document.clone();
                next.upsert(resolved_item.clone())?;
                mesh.note_conflicts.remove(id);
                let tx = storage(open.connection.transaction())?;
                store(&tx, &open.root, &open.header.vault_id, &mesh)?;
                let meta = history::HistoryMeta {
                    item_id: Some(id.to_owned()),
                    actor_type: Some("user".into()),
                    actor: Some("分支合并 · 我".into()),
                    summary: Some(format!("解决并行分支（{}）", cf.section)),
                    milestone: false,
                    coalesce: false,
                };
                let saved = save_document_row_with_prev(
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    Some(&open.document),
                    &next,
                    Some(&meta),
                )?;
                storage(tx.commit())?;
                open.document = saved;
                open.invalidate_hydrated(id);
                Ok(json!({
                    "ok": true,
                    "item": resolved_item,
                    "conflictCount": mesh.note_conflicts.len()
                }))
            }
            "relay-mesh-blob-export" => {
                let peer = string(request, "peer")?;
                let attachment_id = string(request, "attachmentId")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let meta = notes::metas(&open.connection)?
                    .into_iter()
                    .find(|m| m.id == attachment_id)
                    .ok_or(VaultError::InvalidData)?;
                if notes::is_remote(&open.connection, &meta.id)? {
                    return Err(VaultError::Unsupported);
                }
                let bytes = notes::read(
                    &vault_dir,
                    &open.connection,
                    &open.root,
                    &open.header.vault_id,
                    &meta,
                )?;
                Ok(json!({
                    "meta": meta,
                    "data": STANDARD.encode(bytes.as_slice()),
                }))
            }
            "relay-mesh-blob-receive" => {
                let peer = string(request, "peer")?;
                if !mesh.peers.contains(peer) {
                    return Err(VaultError::Authentication);
                }
                let meta: notes::AttachmentMeta = serde_json::from_value(request["meta"].clone())
                    .map_err(|_| VaultError::InvalidData)?;
                let bytes = Zeroizing::new(
                    STANDARD
                        .decode(string(request, "data")?)
                        .map_err(|_| VaultError::InvalidData)?,
                );
                if bytes.len() != meta.size || bytes.len() > crate::archive::FILE_LIMIT {
                    return Err(VaultError::InvalidData);
                }
                let tx = storage(open.connection.transaction())?;
                let existing = notes::metas(&tx)?;
                if let Some(old) = existing.iter().find(|m| m.id == meta.id) {
                    if serde_json::to_value(old).ok() != serde_json::to_value(&meta).ok() {
                        return Err(VaultError::InvalidData);
                    }
                    if !notes::is_remote(&tx, &old.id)?
                        && notes::read(&vault_dir, &tx, &open.root, &open.header.vault_id, old)?
                            .as_slice()
                            != bytes.as_slice()
                    {
                        return Err(VaultError::InvalidData);
                    }
                }
                notes::write(
                    &vault_dir,
                    &tx,
                    &open.root,
                    &open.header.vault_id,
                    &meta,
                    &bytes,
                )?;
                storage(tx.commit())?;
                Ok(json!({"ok": true, "id": meta.id, "state": "ready"}))
            }
            _ => Err(VaultError::Unsupported),
        }
    }

    pub(in crate::native) fn mesh_status(&mut self) -> Result<Option<Value>> {
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Ok(None);
        }
        let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        let peers: BTreeMap<_, _> = mesh
            .peers
            .iter()
            .map(|p| {
                let acked = *mesh.acked.get(p).unwrap_or(&0);
                (
                    p.clone(),
                    json!({"unsent": mesh.meta.values().filter(|m| m.seq > acked).count()}),
                )
            })
            .collect();
        let remote_assets = notes::count_remote(&open.connection).unwrap_or(0);
        let note_conflicts: Vec<&NoteConflict> = mesh.note_conflicts.values().collect();
        Ok(Some(json!({
            "enabled":true,"mode":"mesh","group":mesh.group,"device":mesh.device,
            "peers":peers,"pending":0,"conflictCount":note_conflicts.len(),
            "noteConflicts":note_conflicts,"remoteAssetCount":remote_assets,"skew":mesh.skew,
            "migratedFrom":mesh.migrated_from,"archivedConflicts":mesh.archived_conflicts
        })))
    }

    pub(in crate::native) fn mesh_detach(&mut self, request: &Value) -> Result<Option<Value>> {
        let open = self.open()?;
        if !enabled(&open.connection)? {
            return Ok(None);
        }
        let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
        if string(request, "group")? != mesh.group || string(request, "device")? != mesh.device {
            return Err(VaultError::Authentication);
        }
        let tx = storage(open.connection.transaction())?;
        storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_mesh_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_mesh_archive(payload) SELECT payload FROM personal_mesh; DROP TABLE personal_mesh;"))?;
        storage(tx.commit())?;
        Ok(Some(json!({"ok":true})))
    }

    fn mesh_init(&mut self, request: &Value) -> Result<Value> {
        let group = string(request, "group")?;
        let device = string(request, "device")?;
        if !valid_name(group) || !valid_name(device) {
            return Err(VaultError::InvalidData);
        }
        {
            let open = self.open()?;
            if enabled(&open.connection)? {
                let mesh = load(&open.connection, &open.root, &open.header.vault_id)?;
                if mesh.group == group && mesh.device == device {
                    return Ok(json!({"ok":true,"already":true}));
                }
                return Err(VaultError::AlreadyExists);
            }
        }
        // Stable encrypted snapshot before the journal and history format change.
        let backup = self.directory.join("before-mesh-sync");
        if !backup.exists() {
            let stage = storage(
                tempfile::Builder::new()
                    .prefix(".mesh-backup-")
                    .tempdir_in(&self.directory),
            )?;
            protect_dir(stage.path())?;
            for file in ["header.json", "vault.sqlite"] {
                atomic_write(
                    &stage.path().join(file),
                    &storage(fs::read(self.directory.join(file)))?,
                )?;
            }
            note_blobs::copy_blobs_dir(&self.directory, stage.path())?;
            storage(fs::rename(stage.path(), &backup))?;
        }
        let open = self.open()?;
        let legacy = if super::super::enabled(&open.connection)? {
            Some(super::super::load(
                &open.connection,
                &open.root,
                &open.header.vault_id,
            )?)
        } else {
            None
        };
        let next = open.document.clone();
        let now = now_ms();
        let current = mesh_records(&next);
        let stamps = match &legacy {
            Some(state) if state.group == group => migrate(state, &next, device, now),
            _ => current
                .iter()
                .map(|(key, value)| {
                    let ms = crate::model::timestamp(value).max(0) as u64;
                    (key.clone(), Stamp(ms, 0, device.to_string()))
                })
                .collect(),
        };
        let tx = storage(open.connection.transaction())?;
        let persisted_next =
            note_bodies::sync_and_strip(&tx, &open.root, &open.header.vault_id, &next)?;
        let mut mesh = Mesh {
            version: 1,
            group: group.into(),
            device: device.into(),
            clock: (now, 0),
            seq: 0,
            meta: BTreeMap::new(),
            baseline: Records::new(),
            baseline_digests: mesh_digests(&persisted_next),
            peers: BTreeSet::new(),
            acked: BTreeMap::new(),
            received: BTreeMap::new(),
            ack_sent: BTreeMap::new(),
            skew: false,
            migrated_from: legacy.as_ref().map(|s| s.role.clone()),
            archived_conflicts: 0,
            resent_after_causal_fix: true,
            note_conflicts: BTreeMap::new(),
        };
        for (key, stamp) in stamps {
            mesh.observe(&stamp);
            let seq = mesh.bump()?;
            mesh.meta.insert(
                key,
                Meta {
                    stamp,
                    seq,
                    vv: Versions::new(),
                },
            );
        }
        history::table(&tx)?;
        if legacy.is_some() {
            storage(tx.execute_batch("CREATE TABLE IF NOT EXISTS personal_relay_archive(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO personal_relay_archive(payload) SELECT payload FROM personal_relay; DROP TABLE personal_relay;"))?;
        }
        storage(tx.execute_batch(
            "CREATE TABLE personal_mesh(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL)",
        ))?;
        store(&tx, &open.root, &open.header.vault_id, &mesh)?;
        // Saving first records the current version of every entry in history.
        let saved = save_document_row_with_prev(
            &tx,
            &open.root,
            &open.header.vault_id,
            Some(&open.document),
            &persisted_next,
            None,
        )?;
        if let Some(state) = &legacy {
            // Old hub conflicts become recoverable history instead of a blocking list.
            for conflict in state.conflicts.values() {
                if let Some(id) = conflict.change.key.strip_prefix("item:") {
                    if !conflict.change.value.is_null() {
                        history::write(
                            &tx,
                            &open.root,
                            &open.header.vault_id,
                            &history::Revision::plain(
                                new_id(),
                                id.to_string(),
                                now,
                                conflict.change.value.clone(),
                            ),
                        )?;
                        mesh.archived_conflicts += 1;
                    }
                }
            }
            store(&tx, &open.root, &open.header.vault_id, &mesh)?;
        }
        storage(tx.commit())?;
        let migrated = mesh.migrated_from.clone();
        open.document = saved;
        open.clear_hydrated_cache();
        Ok(json!({"ok":true,"migratedFrom":migrated,"archivedConflicts":mesh.archived_conflicts}))
    }
}
