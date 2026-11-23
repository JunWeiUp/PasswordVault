//! libsodium `crypto_secretstream_xchacha20poly1305`, byte-compatible (including its MAC
//! padding of `mlen & 15` zero bytes after the ciphertext). Used for relay file transfers.
use chacha20::{
    cipher::{consts::U10, KeyIvInit, StreamCipher, StreamCipherSeek},
    hchacha, ChaCha20,
};
use poly1305::{universal_hash::KeyInit, Poly1305};
use zeroize::Zeroize;

pub const KEYBYTES: usize = 32;
pub const HEADERBYTES: usize = 24;
pub const ABYTES: usize = 17;
pub const TAG_MESSAGE: u8 = 0;
pub const TAG_PUSH: u8 = 1;
pub const TAG_REKEY: u8 = 2;
pub const TAG_FINAL: u8 = TAG_PUSH | TAG_REKEY;

pub struct State {
    key: [u8; 32],
    nonce: [u8; 12], // 4-byte LE counter || 8-byte inonce
}

impl Drop for State {
    fn drop(&mut self) {
        self.key.zeroize();
        self.nonce.zeroize();
    }
}

fn keystream_xor(key: &[u8; 32], nonce: &[u8; 12], block_counter: u32, data: &mut [u8]) {
    let mut cipher = ChaCha20::new(key.into(), nonce.into());
    cipher.seek(64u64 * block_counter as u64);
    cipher.apply_keystream(data);
}

impl State {
    fn new(key: &[u8], header: &[u8]) -> Option<Self> {
        if key.len() != KEYBYTES || header.len() != HEADERBYTES {
            return None;
        }
        let sub = hchacha::<U10>(key.into(), header[..16].into());
        let mut state = State {
            key: sub.into(),
            nonce: [0; 12],
        };
        state.nonce[4..].copy_from_slice(&header[16..]);
        state.reset_counter();
        Some(state)
    }

    /// Starts an encrypting stream; returns the state and the header to send.
    pub fn init_push(key: &[u8]) -> Option<(Self, [u8; HEADERBYTES])> {
        let mut header = [0u8; HEADERBYTES];
        getrandom::getrandom(&mut header).ok()?;
        Some((Self::new(key, &header)?, header))
    }

    pub fn init_pull(key: &[u8], header: &[u8]) -> Option<Self> {
        Self::new(key, header)
    }

    fn reset_counter(&mut self) {
        self.nonce[..4].copy_from_slice(&1u32.to_le_bytes());
    }

    fn mac(&self, ad: &[u8], block: &[u8; 64], cipher: &[u8]) -> [u8; 16] {
        let mut poly_key = [0u8; 64];
        keystream_xor(&self.key, &self.nonce, 0, &mut poly_key);
        let mut input = Vec::with_capacity(ad.len() + 16 + 64 + cipher.len() * 2 + 32);
        input.extend_from_slice(ad);
        input.resize(input.len() + ((16 - ad.len() % 16) % 16), 0);
        input.extend_from_slice(block);
        input.extend_from_slice(cipher);
        // libsodium pads with (0x10 - sizeof block + mlen) & 0xf == mlen & 0xf bytes.
        input.resize(input.len() + (cipher.len() & 0xf), 0);
        input.extend_from_slice(&(ad.len() as u64).to_le_bytes());
        input.extend_from_slice(&((64 + cipher.len()) as u64).to_le_bytes());
        let tag =
            Poly1305::new(poly1305::Key::from_slice(&poly_key[..32])).compute_unpadded(&input);
        poly_key.zeroize();
        tag.into()
    }

    fn advance(&mut self, mac: &[u8; 16], tag: u8) {
        for (n, m) in self.nonce[4..].iter_mut().zip(mac) {
            *n ^= m;
        }
        let counter = u32::from_le_bytes(self.nonce[..4].try_into().unwrap()).wrapping_add(1);
        self.nonce[..4].copy_from_slice(&counter.to_le_bytes());
        if tag & TAG_REKEY != 0 || counter == 0 {
            self.rekey();
        }
    }

    fn rekey(&mut self) {
        let mut next = [0u8; 40];
        next[..32].copy_from_slice(&self.key);
        next[32..].copy_from_slice(&self.nonce[4..]);
        keystream_xor(&self.key, &self.nonce, 0, &mut next);
        self.key.copy_from_slice(&next[..32]);
        self.nonce[4..].copy_from_slice(&next[32..]);
        next.zeroize();
        self.reset_counter();
    }

    pub fn push(&mut self, message: &[u8], ad: &[u8], tag: u8) -> Vec<u8> {
        let mut block = [0u8; 64];
        block[0] = tag;
        keystream_xor(&self.key, &self.nonce, 1, &mut block);
        let mut out = Vec::with_capacity(message.len() + ABYTES);
        out.push(block[0]);
        let mut cipher = message.to_vec();
        keystream_xor(&self.key, &self.nonce, 2, &mut cipher);
        let mac = self.mac(ad, &block, &cipher);
        out.extend_from_slice(&cipher);
        out.extend_from_slice(&mac);
        self.advance(&mac, tag);
        out
    }

    /// Returns the plaintext and tag, or None when authentication fails.
    pub fn pull(&mut self, input: &[u8], ad: &[u8]) -> Option<(Vec<u8>, u8)> {
        if input.len() < ABYTES {
            return None;
        }
        let mlen = input.len() - ABYTES;
        let mut block = [0u8; 64];
        block[0] = input[0];
        keystream_xor(&self.key, &self.nonce, 1, &mut block);
        let tag = block[0];
        block[0] = input[0];
        let cipher = &input[1..1 + mlen];
        let mac = self.mac(ad, &block, cipher);
        let stored = &input[1 + mlen..];
        if mac
            .iter()
            .zip(stored)
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            != 0
        {
            return None;
        }
        let mut plain = cipher.to_vec();
        keystream_xor(&self.key, &self.nonce, 2, &mut plain);
        self.advance(&mac, tag);
        Some((plain, tag))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_rekey_and_tamper() {
        let key = [7u8; 32];
        let (mut push, header) = State::init_push(&key).unwrap();
        let mut pull = State::init_pull(&key, &header).unwrap();
        let parts: Vec<Vec<u8>> = vec![
            b"a".to_vec(),
            vec![1; 31],
            vec![2; 65519],
            vec![],
            b"after rekey".to_vec(),
            vec![],
        ];
        let tags = [
            TAG_MESSAGE,
            TAG_MESSAGE,
            TAG_PUSH,
            TAG_REKEY,
            TAG_MESSAGE,
            TAG_FINAL,
        ];
        for (part, tag) in parts.iter().zip(tags) {
            let block = push.push(part, b"ad", tag);
            assert_eq!(block.len(), part.len() + ABYTES);
            let mut bad = block.clone();
            *bad.last_mut().unwrap() ^= 1;
            let mut probe = State {
                key: pull.key,
                nonce: pull.nonce,
            };
            assert!(probe.pull(&bad, b"ad").is_none());
            assert!(State {
                key: pull.key,
                nonce: pull.nonce
            }
            .pull(&block, b"other")
            .is_none());
            assert_eq!(pull.pull(&block, b"ad").unwrap(), (part.clone(), tag));
        }
    }
}
