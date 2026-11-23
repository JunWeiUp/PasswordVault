//! Reject ambiguous signed JSON before serde can normalize it.
const MEMBER: &[(&str, u8, bool)] = &[
    ("device", b's', true),
    ("name", b's', true),
    ("public_key", b's', true),
    ("signing_key", b's', true),
    ("manager", b'b', true),
];
const STATE: &[(&str, u8, bool)] = &[
    ("closed", b'b', false),
    ("name", b's', false),
    ("version", b'i', true),
    ("app", b's', true),
    ("group", b's', true),
    ("revision", b'i', true),
    ("previous", b's', true),
    ("members", b'M', true),
    ("invitation", b's', true),
    ("request_hash", b's', true),
];
const REQUEST: &[(&str, u8, bool)] = &[
    ("version", b'i', true),
    ("app", b's', true),
    ("group", b's', true),
    ("invitation", b's', true),
    ("member", b'm', true),
    ("token_hash", b's', true),
];
const GRANT: &[(&str, u8, bool)] = &[
    ("version", b'i', true),
    ("purpose", b's', true),
    ("mode", b's', true),
    ("app", b's', true),
    ("group", b's', true),
    ("invitation", b's', true),
    ("expires", b'i', true),
    ("secret_hash", b's', true),
    ("delegate_key", b's', true),
    ("anchor_revision", b'i', true),
    ("anchor_hash", b's', true),
];
pub fn check(b: &[u8]) -> bool {
    if std::str::from_utf8(b).is_err() {
        return false;
    }
    [STATE, REQUEST, GRANT].iter().any(|schema| {
        let mut p = Parser { b, i: 0 };
        p.object(schema) && {
            p.ws();
            p.i == b.len()
        }
    })
}
struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}
impl Parser<'_> {
    fn ws(&mut self) {
        while self.b.get(self.i).is_some_and(|c| b" \t\r\n".contains(c)) {
            self.i += 1;
        }
    }
    fn eat(&mut self, c: u8) -> bool {
        self.ws();
        if self.b.get(self.i) == Some(&c) {
            self.i += 1;
            true
        } else {
            false
        }
    }
    fn string(&mut self) -> bool {
        if self.b.get(self.i) != Some(&b'"') {
            return false;
        }
        self.i += 1;
        while let Some(&c) = self.b.get(self.i) {
            self.i += 1;
            if c == b'"' {
                return true;
            }
            if c < 32 {
                return false;
            }
            if c == b'\\' {
                let Some(&e) = self.b.get(self.i) else {
                    return false;
                };
                self.i += 1;
                if e == b'u' {
                    let Some(raw) = self.b.get(self.i..self.i + 4) else {
                        return false;
                    };
                    let Ok(s) = std::str::from_utf8(raw) else {
                        return false;
                    };
                    let Ok(n) = u16::from_str_radix(s, 16) else {
                        return false;
                    };
                    if (0xd800..=0xdfff).contains(&n) {
                        return false;
                    }
                    self.i += 4;
                } else if !b"\"\\/bfnrt".contains(&e) {
                    return false;
                }
            }
        }
        false
    }
    fn object(&mut self, schema: &[(&str, u8, bool)]) -> bool {
        if !self.eat(b'{') {
            return false;
        }
        let mut seen = std::collections::BTreeSet::new();
        if !self.eat(b'}') {
            loop {
                self.ws();
                let start = self.i;
                if !self.string() {
                    return false;
                }
                let Ok(key) = std::str::from_utf8(&self.b[start + 1..self.i - 1]) else {
                    return false;
                };
                let Some((_, kind, _)) = schema.iter().find(|f| f.0 == key) else {
                    return false;
                };
                if !seen.insert(key) || !self.eat(b':') || !self.value(*kind) {
                    return false;
                }
                if self.eat(b'}') {
                    break;
                }
                if !self.eat(b',') {
                    return false;
                }
            }
        }
        schema
            .iter()
            .all(|(k, _, required)| !*required || seen.contains(k))
    }
    fn value(&mut self, kind: u8) -> bool {
        self.ws();
        match kind {
            b's' => self.string(),
            b'm' => self.object(MEMBER),
            b'b' => {
                for word in [b"true".as_slice(), b"false".as_slice()] {
                    if self.b.get(self.i..self.i + word.len()) == Some(word) {
                        self.i += word.len();
                        return true;
                    }
                }
                false
            }
            b'i' => {
                let start = self.i;
                while self.b.get(self.i).is_some_and(u8::is_ascii_digit) {
                    self.i += 1;
                }
                let raw = &self.b[start..self.i];
                if raw.is_empty() || (raw.len() > 1 && raw[0] == b'0') {
                    return false;
                }
                std::str::from_utf8(raw)
                    .ok()
                    .and_then(|s| s.parse::<u64>().ok())
                    .is_some_and(|n| n <= 9_007_199_254_740_991)
            }
            b'M' => {
                if !self.eat(b'[') {
                    return false;
                }
                if self.eat(b']') {
                    return true;
                }
                loop {
                    if !self.object(MEMBER) {
                        return false;
                    }
                    if self.eat(b']') {
                        return true;
                    }
                    if !self.eat(b',') {
                        return false;
                    }
                }
            }
            _ => false,
        }
    }
}
