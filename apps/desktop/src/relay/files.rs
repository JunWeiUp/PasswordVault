//! Common-relay secretstream files, with CryptoKit-compatible inner AES-GCM.
use super::{
    Result, invalid,
    protocol::*,
    transport::{Identity, endpoint},
};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::Aead};
use serde_json::{Value, json};
use sodiumoxide::crypto::secretstream::xchacha20poly1305 as stream;
use std::{io::Read, time::Duration};
const MAX: usize = 768 * 1024 * 1024;
fn aad(i: &Identity, from: &str, to: &str, id: &str, sequence: u64) -> Vec<u8> {
    canonical(&json!([1, i.app, i.group, from, to, "file", id, sequence]))
}
pub fn prepare(i: &Identity, to: &str, plain: &[u8]) -> Result<(Value, Vec<u8>)> {
    if plain.len() > MAX {
        return Err("RelayFileTooLarge".into());
    }
    let key = zeroize::Zeroizing::new(sodiumoxide::randombytes::randombytes(32));
    let nonce = sodiumoxide::randombytes::randombytes(12);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    let mut inner = nonce.clone();
    inner.extend(
        aes.encrypt(Nonce::from_slice(&nonce), plain)
            .map_err(|_| "Authentication")?,
    );
    let id = uuid::Uuid::new_v4().simple().to_string();
    let stream_key = stream::gen_key();
    let (mut writer, header) = stream::Stream::init_push(&stream_key).map_err(|_| "InvalidData")?;
    let mut cipher = vec![];
    let mut sequence = 0;
    for part in inner.chunks(65519).chain(std::iter::once(&[][..])) {
        let tag = if part.is_empty() {
            stream::Tag::Final
        } else {
            stream::Tag::Message
        };
        let block = writer
            .push(part, Some(&aad(i, &i.device, to, &id, sequence)), tag)
            .map_err(|_| "Authentication")?;
        cipher.extend((block.len() as u32).to_be_bytes());
        cipher.extend(block);
        sequence += 1;
    }
    let metadata=i.seal(to,"file",&id,json!({"key":hex(&stream_key.0),"header":hex(&header.0),"metadata":{"format":"passwordvault.sync.v1","key":hex(&key)}}))?;
    Ok((
        json!({"id":id,"to":to,"size":cipher.len(),"sha256":digest(&cipher),"metadata":metadata}),
        cipher,
    ))
}
pub fn decrypt(
    i: &Identity,
    from: &str,
    descriptor: &Value,
    cipher: &[u8],
) -> Result<zeroize::Zeroizing<Vec<u8>>> {
    if cipher.len() > MAX
        || descriptor["size"].as_u64() != Some(cipher.len() as u64)
        || descriptor["sha256"] != digest(cipher)
    {
        return invalid();
    }
    let id = text(descriptor, "id")?;
    let wrapped = i.open(from, "file", id, text(descriptor, "metadata")?)?;
    let key = stream::Key::from_slice(&unhex(text(&wrapped, "key")?)?).ok_or("InvalidData")?;
    let header =
        stream::Header::from_slice(&unhex(text(&wrapped, "header")?)?).ok_or("InvalidData")?;
    let mut reader = stream::Stream::init_pull(&header, &key).map_err(|_| "Authentication")?;
    let mut pos = 0;
    let mut sequence = 0;
    let mut final_seen = false;
    let mut inner = zeroize::Zeroizing::new(Vec::new());
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
                Some(&aad(i, from, &i.device, id, sequence)),
            )
            .map_err(|_| "Authentication")?;
        if !matches!(tag, stream::Tag::Message | stream::Tag::Final) {
            return invalid();
        }
        inner.extend(block);
        final_seen = tag == stream::Tag::Final;
        pos += n;
        sequence += 1;
    }
    if !final_seen || inner.len() < 28 || wrapped["metadata"]["format"] != "passwordvault.sync.v1" {
        return invalid();
    }
    let key = zeroize::Zeroizing::new(unhex(text(&wrapped["metadata"], "key")?)?);
    let aes = Aes256Gcm::new_from_slice(&key).map_err(|_| "InvalidData")?;
    Ok(zeroize::Zeroizing::new(
        aes.decrypt(Nonce::from_slice(&inner[..12]), &inner[12..])
            .map_err(|_| "Authentication")?,
    ))
}
pub struct Files<'a> {
    base: String,
    token: String,
    password: Option<String>,
    check: &'a dyn Fn() -> Result<()>,
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
            .map(|p| super::protocol::access_password(p).map(str::to_owned))
            .transpose()?;
        let mut u = endpoint(url, local)?;
        u.set_scheme(if u.scheme() == "wss" { "https" } else { "http" })
            .map_err(|_| "InvalidData")?;
        u.set_path("/relay/v1/files");
        Ok(Self {
            base: u.to_string(),
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
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "RelayConnection")?;
        let url = if path.is_empty() {
            self.base.clone()
        } else {
            format!("{}/{path}", self.base)
        };
        let mut req = client
            .request(method.parse().map_err(|_| "InvalidData")?, url)
            .bearer_auth(&self.token)
            .body(body);
        if let Some(password) = &self.password {
            req = req.header(super::protocol::ACCESS_HEADER, password);
        }
        for (k, v) in headers {
            req = req.header(*k, v);
        }
        let res = req.send().map_err(|_| "RelayConnection")?;
        let status = res.status().as_u16();
        let mut bytes = vec![];
        res.take(3 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "RelayConnection")?;
        if bytes.len() > 3 * 1024 * 1024 {
            return invalid();
        }
        (self.check)()?;
        Ok((status, bytes))
    }
    fn object(raw: &[u8]) -> Result<Value> {
        serde_json::from_slice(raw).map_err(|_| "InvalidData".into())
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
        let existing = Self::object(&raw)?;
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
            if status != 200 || Self::object(&raw)?["offset"].as_u64() != Some(end as u64) {
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
        let v = Self::object(&raw)?;
        v.as_array().cloned().ok_or("InvalidData".into())
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
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
    };
    fn identities() -> (Identity, Identity) {
        let (ap, a) = sodiumoxide::crypto::box_::gen_keypair();
        let (bp, b) = sodiumoxide::crypto::box_::gen_keypair();
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
        sodiumoxide::init().unwrap();
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
