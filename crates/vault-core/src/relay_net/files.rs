//! Relay file transfers: a common-relay secretstream outer layer (sealed descriptor in the
//! envelope) around a CryptoKit-compatible AES-GCM inner layer (`passwordvault.sync.v1`).
use super::{http, invalid, random_hex, Result};
use crate::relay_protocol::{
    canonical, digest, endpoint, hex, secretstream, text, unhex, Identity, ACCESS_HEADER,
};
use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use serde_json::{json, Value};
use zeroize::Zeroizing;

pub const MAX: usize = 768 * 1024 * 1024;
const RECORD: usize = 65519;

fn aad(i: &Identity, from: &str, to: &str, id: &str, sequence: u64) -> Vec<u8> {
    canonical(&json!([1, i.app, i.group, from, to, "file", id, sequence]))
}

fn random(n: usize) -> Zeroizing<Vec<u8>> {
    let mut bytes = Zeroizing::new(vec![0u8; n]);
    getrandom::getrandom(&mut bytes).expect("system randomness");
    bytes
}

/// Encrypts `plain` for `to`; returns the upload descriptor and the staged ciphertext.
pub fn prepare(i: &Identity, to: &str, plain: &[u8]) -> Result<(Value, Vec<u8>)> {
    if plain.len() > MAX {
        return Err("RelayFileTooLarge".into());
    }
    let key = random(32);
    let nonce = random(12);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    let mut inner = Zeroizing::new(nonce.to_vec());
    inner.extend(
        aes.encrypt(Nonce::from_slice(&nonce), plain)
            .map_err(|_| "Authentication")?,
    );
    let id = random_hex(16);
    let stream_key = random(32);
    let (mut writer, header) = secretstream::State::init_push(&stream_key).ok_or("Storage")?;
    let mut cipher = vec![];
    for (sequence, part) in inner
        .chunks(RECORD)
        .chain(std::iter::once(&[][..]))
        .enumerate()
    {
        let tag = if part.is_empty() {
            secretstream::TAG_FINAL
        } else {
            secretstream::TAG_MESSAGE
        };
        let block = writer.push(part, &aad(i, &i.device, to, &id, sequence as u64), tag);
        cipher.extend((block.len() as u32).to_be_bytes());
        cipher.extend(block);
    }
    let metadata = i.seal(
        to,
        "file",
        &id,
        json!({"key":hex(&stream_key),"header":hex(&header),"metadata":{"format":"passwordvault.sync.v1","key":hex(&key)}}),
    )?;
    Ok((
        json!({"id":id,"to":to,"size":cipher.len(),"sha256":digest(&cipher),"metadata":metadata}),
        cipher,
    ))
}

/// Verifies and decrypts a downloaded file from `from`.
pub fn decrypt(
    i: &Identity,
    from: &str,
    descriptor: &Value,
    cipher: &[u8],
) -> Result<Zeroizing<Vec<u8>>> {
    if cipher.len() > MAX
        || descriptor["size"].as_u64() != Some(cipher.len() as u64)
        || descriptor["sha256"] != digest(cipher)
    {
        return invalid();
    }
    let id = text(descriptor, "id")?;
    let wrapped = i.open(from, "file", id, text(descriptor, "metadata")?)?;
    let key = Zeroizing::new(unhex(text(&wrapped, "key")?)?);
    let header = unhex(text(&wrapped, "header")?)?;
    let mut reader = secretstream::State::init_pull(&key, &header).ok_or("InvalidData")?;
    let (mut pos, mut sequence, mut final_seen) = (0, 0u64, false);
    let mut inner = Zeroizing::new(Vec::new());
    while pos < cipher.len() {
        if final_seen || pos + 4 > cipher.len() {
            return invalid();
        }
        let n = u32::from_be_bytes(cipher[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        if !(17..=65536).contains(&n) || pos + n > cipher.len() {
            return invalid();
        }
        let (block, tag) = reader
            .pull(
                &cipher[pos..pos + n],
                &aad(i, from, &i.device, id, sequence),
            )
            .ok_or("Authentication")?;
        if tag != secretstream::TAG_MESSAGE && tag != secretstream::TAG_FINAL {
            return invalid();
        }
        inner.extend(block);
        final_seen = tag == secretstream::TAG_FINAL;
        pos += n;
        sequence += 1;
    }
    if !final_seen || inner.len() < 28 || wrapped["metadata"]["format"] != "passwordvault.sync.v1" {
        return invalid();
    }
    let key = Zeroizing::new(unhex(text(&wrapped["metadata"], "key")?)?);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    Ok(Zeroizing::new(
        aes.decrypt(Nonce::from_slice(&inner[..12]), &inner[12..])
            .map_err(|_| "Authentication")?,
    ))
}

/// HTTPS file API (`/relay/v1/files` or `/v2/files`). `check` runs around each request so a
/// caller can abort a transfer (e.g. when the vault locks).
pub struct Files<'a> {
    base: String,
    token: String,
    password: Option<String>,
    check: &'a dyn Fn() -> Result<()>,
}

fn object(raw: &[u8]) -> Result<Value> {
    serde_json::from_slice(raw).map_err(|_| "InvalidData".into())
}

impl<'a> Files<'a> {
    pub fn new(
        url: &str,
        token: &str,
        password: Option<&str>,
        local: bool,
        check: &'a dyn Fn() -> Result<()>,
    ) -> Result<Self> {
        let password = password
            .map(|p| crate::relay_protocol::access_password(p).map(str::to_owned))
            .transpose()?;
        endpoint(url, local)?;
        Ok(Self {
            base: format!("{}/files", http::base(url, local)?),
            token: token.into(),
            password,
            check,
        })
    }

    fn request(
        &self,
        method: &str,
        path: &str,
        body: Vec<u8>,
        headers: &[(&str, String)],
    ) -> Result<(u16, Vec<u8>)> {
        (self.check)()?;
        if path.contains("..") || path.contains('?') || path.contains('#') {
            return invalid();
        }
        let url = if path.is_empty() {
            self.base.clone()
        } else {
            format!("{}/{path}", self.base)
        };
        let mut req = http::client()?
            .request(method.parse().map_err(|_| "InvalidData")?, url)
            .bearer_auth(&self.token)
            .body(body);
        if let Some(password) = &self.password {
            req = req.header(ACCESS_HEADER, password);
        }
        for (k, v) in headers {
            req = req.header(*k, v);
        }
        let res = req.send().map_err(|_| "RelayConnection")?;
        let status = res.status().as_u16();
        let bytes = http::read_limited(res)?.to_vec();
        (self.check)()?;
        Ok((status, bytes))
    }

    pub fn upload(&self, d: &Value, cipher: &[u8]) -> Result<()> {
        let id = text(d, "id")?;
        if unhex(id)?.len() != 16 {
            return invalid();
        }
        let (mut status, mut raw) = self.request(
            "POST",
            "",
            canonical(d),
            &[("Content-Type", "application/json".into())],
        )?;
        if status == 409 {
            (status, raw) = self.request("GET", id, vec![], &[])?;
        }
        if status != 200 && status != 201 {
            return Err(format!("RelayFileHttp{status}"));
        }
        let existing = object(&raw)?;
        for field in ["id", "to", "size", "sha256", "metadata"] {
            if existing[field] != d[field] {
                return Err("RelayUploadConflict".into());
            }
        }
        let mut offset = existing["offset"].as_u64().ok_or("InvalidData")? as usize;
        if offset > cipher.len() {
            return invalid();
        }
        while offset < cipher.len() {
            let end = (offset + 1024 * 1024).min(cipher.len());
            let (status, raw) = self.request(
                "PUT",
                &format!("{id}/data"),
                cipher[offset..end].to_vec(),
                &[("Upload-Offset", offset.to_string())],
            )?;
            if status != 200 || object(&raw)?["offset"].as_u64() != Some(end as u64) {
                return invalid();
            }
            offset = end;
        }
        let (status, _) = self.request("POST", &format!("{id}/commit"), vec![], &[])?;
        if status != 200 {
            return Err(format!("RelayFileHttp{status}"));
        }
        Ok(())
    }

    pub fn inbox(&self) -> Result<Vec<Value>> {
        let (status, raw) = self.request("GET", "", vec![], &[])?;
        if status != 200 {
            return Err(format!("RelayFileHttp{status}"));
        }
        object(&raw)?
            .as_array()
            .cloned()
            .ok_or("InvalidData".into())
    }

    pub fn download(&self, d: &Value) -> Result<Vec<u8>> {
        let id = text(d, "id")?;
        if unhex(id)?.len() != 16 {
            return invalid();
        }
        let size = d["size"].as_u64().ok_or("InvalidData")? as usize;
        if size > MAX {
            return Err("RelayFileTooLarge".into());
        }
        let mut cipher = Vec::with_capacity(size);
        while cipher.len() < size {
            let end = (cipher.len() + 1024 * 1024).min(size) - 1;
            let (status, part) = self.request(
                "GET",
                &format!("{id}/data"),
                vec![],
                &[("Range", format!("bytes={}-{end}", cipher.len()))],
            )?;
            if status != 206 || part.len() != end + 1 - cipher.len() {
                return invalid();
            }
            cipher.extend(part);
        }
        Ok(cipher)
    }

    pub fn acknowledge(&self, id: &str) -> Result<()> {
        if unhex(id)?.len() != 16 {
            return invalid();
        }
        let (status, _) = self.request("DELETE", id, vec![], &[])?;
        if status != 204 {
            return Err(format!("RelayFileHttp{status}"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay_protocol::box_keypair;

    #[test]
    fn prepared_files_decrypt_only_for_the_recipient() {
        let (ap, a) = box_keypair();
        let (bp, b) = box_keypair();
        let alice = Identity {
            app: "passwordvault".into(),
            group: "g".into(),
            device: "a".into(),
            secret: a,
            trusted: [("b".into(), bp)].into(),
        };
        let bob = Identity {
            app: "passwordvault".into(),
            group: "g".into(),
            device: "b".into(),
            secret: b,
            trusted: [("a".into(), ap)].into(),
        };
        let plain = vec![9u8; 200_000];
        let (descriptor, cipher) = prepare(&alice, "b", &plain).unwrap();
        assert_eq!(&*decrypt(&bob, "a", &descriptor, &cipher).unwrap(), &plain);
        let mut tampered = cipher.clone();
        tampered[100] ^= 1;
        assert!(decrypt(&bob, "a", &descriptor, &tampered).is_err());
        assert!(decrypt(&alice, "b", &descriptor, &cipher).is_err());
    }

    mod http_resume {
        use super::super::*;
        use serde_json::{json, Value};
        use std::time::Duration;

        use std::{
            io::{Read, Write},
            net::TcpListener,
            sync::{
                atomic::{AtomicBool, Ordering},
                Arc,
            },
        };
        fn identities() -> (Identity, Identity) {
            let (ap, a) = crate::relay_protocol::box_keypair();
            let (bp, b) = crate::relay_protocol::box_keypair();
            (
                Identity {
                    app: "passwordvault".into(),
                    group: "qa".into(),
                    device: "a".into(),
                    secret: a,
                    trusted: [("b".into(), bp)].into(),
                },
                Identity {
                    app: "passwordvault".into(),
                    group: "qa".into(),
                    device: "b".into(),
                    secret: b,
                    trusted: [("a".into(), ap)].into(),
                },
            )
        }
        #[test]
        fn relay_file_secretstream_context_truncation_and_local_http_resume() {
            let (a, b) = identities();
            let plain = vec![b'x'; 1_100_000];
            let (descriptor, cipher) = prepare(&a, "b", &plain).unwrap();
            assert_eq!(&*decrypt(&b, "a", &descriptor, &cipher).unwrap(), &plain);
            assert!(decrypt(&b, "a", &descriptor, &cipher[..cipher.len() - 1]).is_err());
            let mut corrupted = cipher.clone();
            corrupted[40] ^= 1;
            assert!(decrypt(&b, "a", &descriptor, &corrupted).is_err());
            let mut wrong = descriptor.clone();
            wrong["id"] = json!("00".repeat(16));
            assert!(decrypt(&b, "a", &wrong, &cipher).is_err());
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let flag = stop.clone();
            let server = std::thread::spawn(move || {
                let mut meta = Value::Null;
                let mut data = vec![];
                let mut committed = false;
                for socket in listener.incoming() {
                    if flag.load(Ordering::SeqCst) {
                        break;
                    }
                    let mut socket = socket.unwrap();
                    socket
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut header = vec![];
                    let mut one = [0];
                    while !header.ends_with(b"\r\n\r\n") {
                        socket.read_exact(&mut one).unwrap();
                        header.push(one[0]);
                    }
                    let header = String::from_utf8(header).unwrap();
                    let mut lines = header.lines();
                    let mut first = lines.next().unwrap().split_whitespace();
                    let method = first.next().unwrap();
                    let path = first
                        .next()
                        .unwrap()
                        .strip_prefix("/relay/v1/files")
                        .unwrap();
                    let headers: std::collections::BTreeMap<_, _> = lines
                        .filter_map(|l| l.split_once(':'))
                        .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().to_owned()))
                        .collect();
                    assert_eq!(headers["authorization"], "Bearer synthetic-file-token");
                    assert_eq!(headers["relay-access"], "synthetic-access");
                    let len = headers
                        .get("content-length")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0);
                    let mut body = vec![0; len];
                    socket.read_exact(&mut body).unwrap();
                    let (status, reply) = if method == "POST" && path.is_empty() {
                        if meta.is_null() {
                            meta = serde_json::from_slice(&body).unwrap();
                            meta["offset"] = json!(0);
                            (201, canonical(&meta))
                        } else {
                            (409, vec![])
                        }
                    } else if method == "PUT" && path.ends_with("/data") {
                        assert_eq!(
                            headers["upload-offset"].parse::<usize>().unwrap(),
                            data.len()
                        );
                        data.extend(body);
                        meta["offset"] = json!(data.len());
                        (200, canonical(&json!({"offset":data.len()})))
                    } else if method == "POST" && path.ends_with("/commit") {
                        assert_eq!(meta["size"], data.len());
                        committed = true;
                        (200, canonical(&meta))
                    } else if method == "GET" && path.ends_with("/data") {
                        let range = headers["range"].trim_start_matches("bytes=");
                        let (a, b) = range.split_once('-').unwrap();
                        let (a, b): (usize, usize) = (a.parse().unwrap(), b.parse().unwrap());
                        (206, data[a..=b].to_vec())
                    } else if method == "GET" && path.is_empty() {
                        let mut item = meta.clone();
                        item["from"] = json!("a");
                        (
                            200,
                            canonical(&if committed { json!([item]) } else { json!([]) }),
                        )
                    } else if method == "GET" {
                        (200, canonical(&meta))
                    } else if method == "DELETE" {
                        committed = false;
                        (204, vec![])
                    } else {
                        (404, vec![])
                    };
                    write!(
                        socket,
                        "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        reply.len()
                    )
                    .unwrap();
                    socket.write_all(&reply).unwrap();
                }
            });
            let check = || Ok(());
            let files = Files::new(
                &format!("ws://{address}/relay/v1/ws"),
                "synthetic-file-token",
                Some("synthetic-access"),
                true,
                &check,
            )
            .unwrap();
            files
                .request("POST", "", canonical(&descriptor), &[])
                .unwrap();
            let id = text(&descriptor, "id").unwrap();
            files
                .request(
                    "PUT",
                    &format!("{id}/data"),
                    cipher[..1000].to_vec(),
                    &[("Upload-Offset", "0".into())],
                )
                .unwrap();
            files.upload(&descriptor, &cipher).unwrap();
            let inbox = files.inbox().unwrap();
            assert_eq!(inbox.len(), 1);
            let downloaded = files.download(&inbox[0]).unwrap();
            assert_eq!(downloaded, cipher);
            assert_eq!(&*decrypt(&b, "a", &inbox[0], &downloaded).unwrap(), &plain);
            files.acknowledge(id).unwrap();
            assert!(files.inbox().unwrap().is_empty());
            let denied = || Err("Locked".into());
            let locked = Files::new(
                &format!("ws://{address}/relay/v1/ws"),
                "synthetic-file-token",
                Some("synthetic-access"),
                true,
                &denied,
            )
            .unwrap();
            assert!(locked.upload(&descriptor, &cipher).is_err());
            stop.store(true, Ordering::SeqCst);
            let _ = std::net::TcpStream::connect(address);
            server.join().unwrap();
        }
    }
}
