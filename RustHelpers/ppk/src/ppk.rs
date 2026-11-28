use aes::Aes256;
use argon2::{Algorithm as ArgonAlgorithm, Argon2, Params, Version as ArgonVersion};
use base64::{Engine, engine::general_purpose::STANDARD};
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::NoPadding};
use hmac::{Hmac, Mac};
use sha1::{Digest, Sha1};
use sha2::Sha256;
use ssh_key::{
    PrivateKey, PublicKey,
    encoding::{Decode, Reader},
    private::{Ed25519Keypair, KeypairData},
};
use zeroize::Zeroizing;

pub const MAX_FILE_BYTES: usize = 1_048_576;
const MAX_ARGON_MEMORY_KIB: u32 = 262_144;
const MAX_ARGON_PASSES: u32 = 128;
const MAX_ARGON_PARALLELISM: u32 = 16;
const MAC_KEY_LABEL: &[u8] = b"putty-private-key-file-mac-key";

#[derive(Clone, Copy)]
enum Version {
    V2,
    V3,
}

enum Protection {
    Plain,
    AesV2,
    AesV3 {
        algorithm: ArgonAlgorithm,
        params: Params,
        salt: Vec<u8>,
    },
}

struct Ppk<'a> {
    version: Version,
    algorithm: &'a [u8],
    encryption: &'a [u8],
    protection: Protection,
    comment: &'a [u8],
    public_blob: Zeroizing<Vec<u8>>,
    private_blob: Zeroizing<Vec<u8>>,
    mac: Vec<u8>,
}

pub fn convert(source: &[u8], password: &[u8]) -> Option<PrivateKey> {
    let mut ppk = Ppk::parse(source)?;
    ppk.authenticate(password)?;
    ppk.to_private_key()
}

impl<'a> Ppk<'a> {
    fn parse(source: &'a [u8]) -> Option<Self> {
        let mut lines = source
            .split(|byte| matches!(byte, b'\r' | b'\n'))
            .filter(|line| !line.is_empty());
        let header = lines.next()?.strip_prefix(b"PuTTY-User-Key-File-")?;
        let (version, algorithm) = if let Some(algorithm) = header.strip_prefix(b"2: ") {
            (Version::V2, algorithm)
        } else {
            (Version::V3, header.strip_prefix(b"3: ")?)
        };
        match algorithm {
            b"ssh-ed25519"
            | b"ssh-rsa"
            | b"ssh-dss"
            | b"ecdsa-sha2-nistp256"
            | b"ecdsa-sha2-nistp384"
            | b"ecdsa-sha2-nistp521" => (),
            _ => return None,
        }

        let encryption = field(&mut lines, b"Encryption: ")?;
        let comment = field(&mut lines, b"Comment: ")?;
        let public_blob = block(&mut lines, b"Public-Lines: ")?;
        let protection = match (version, encryption) {
            (_, b"none") => Protection::Plain,
            (Version::V2, b"aes256-cbc") => Protection::AesV2,
            (Version::V3, b"aes256-cbc") => argon_parameters(&mut lines)?,
            _ => return None,
        };
        let private_blob = block(&mut lines, b"Private-Lines: ")?;
        let mac = hex::decode(field(&mut lines, b"Private-MAC: ")?).ok()?;
        let mac_size = match version {
            Version::V2 => 20,
            Version::V3 => 32,
        };
        (mac.len() == mac_size && lines.next().is_none()).then_some(Self {
            version,
            algorithm,
            encryption,
            protection,
            comment,
            public_blob,
            private_blob,
            mac,
        })
    }

    fn authenticate(&mut self, password: &[u8]) -> Option<()> {
        match &self.protection {
            Protection::Plain => match self.version {
                Version::V2 => self.verify_v2(b""),
                Version::V3 => self.verify::<Hmac<Sha256>>(b""),
            },
            Protection::AesV2 => {
                // PPK v2 concatenates two SHA-1 blocks and keeps the first 32 bytes.
                let mut key = Zeroizing::new([0u8; 40]);
                for (counter, block) in key.as_chunks_mut::<20>().0.iter_mut().enumerate() {
                    let mut hash = Sha1::new();
                    hash.update((counter as u32).to_be_bytes());
                    hash.update(password);
                    let digest = Zeroizing::new(<[u8; 20]>::from(hash.finalize()));
                    block.copy_from_slice(&*digest);
                }
                decrypt(&key[..32], &[0u8; 16], &mut self.private_blob)?;
                self.verify_v2(password)
            }
            Protection::AesV3 {
                algorithm,
                params,
                salt,
            } => {
                let mut material = Zeroizing::new([0u8; 80]);
                Argon2::new(*algorithm, ArgonVersion::V0x13, params.clone())
                    .hash_password_into(password, salt, &mut *material)
                    .ok()?;
                decrypt(&material[..32], &material[32..48], &mut self.private_blob)?;
                self.verify::<Hmac<Sha256>>(&material[48..])
            }
        }
    }

    fn verify_v2(&self, password: &[u8]) -> Option<()> {
        let mut hash = Sha1::new();
        hash.update(MAC_KEY_LABEL);
        hash.update(password);
        let key = Zeroizing::new(<[u8; 20]>::from(hash.finalize()));
        self.verify::<Hmac<Sha1>>(&*key)
    }

    fn verify<M: Mac + hmac::digest::KeyInit>(&self, key: &[u8]) -> Option<()> {
        let mut mac = <M as Mac>::new_from_slice(key).ok()?;
        for field in [
            self.algorithm,
            self.encryption,
            self.comment,
            &self.public_blob,
            &self.private_blob,
        ] {
            mac.update(&(field.len() as u32).to_be_bytes());
            mac.update(field);
        }
        mac.verify_slice(&self.mac).ok()
    }

    fn to_private_key(&self) -> Option<PrivateKey> {
        let public = PublicKey::from_bytes(&self.public_blob).ok()?;
        let mut public_fields = self.public_blob.as_slice();
        let mut private_fields = self.private_blob.as_slice();
        if take_ssh_field(&mut public_fields)? != self.algorithm {
            return None;
        }
        let key_data = match self.algorithm {
            b"ssh-ed25519" => {
                // PuTTY stores a little-endian seed as an SSH string.
                let seed_field = take_ssh_field(&mut private_fields)?;
                let mut seed = Zeroizing::new([0u8; 32]);
                seed.get_mut(..seed_field.len())?
                    .copy_from_slice(seed_field);
                KeypairData::Ed25519(Ed25519Keypair::from_seed(&seed))
            }
            _ => {
                let mut encoded = Zeroizing::new(Vec::with_capacity(
                    self.public_blob.len() + self.private_blob.len(),
                ));
                ssh_field(&mut encoded, self.algorithm);
                if self.algorithm == b"ssh-rsa" {
                    let e = take_ssh_field(&mut public_fields)?;
                    let n = take_ssh_field(&mut public_fields)?;
                    let d = take_ssh_field(&mut private_fields)?;
                    let p = take_ssh_field(&mut private_fields)?;
                    let q = take_ssh_field(&mut private_fields)?;
                    let iqmp = take_ssh_field(&mut private_fields)?;
                    // OpenSSH orders RSA fields differently from PPK.
                    for value in [n, e, d, iqmp, p, q] {
                        ssh_field(&mut encoded, value);
                    }
                } else {
                    encoded.extend_from_slice(public_fields);
                    let scalar = take_ssh_field(&mut private_fields)?;
                    match self.algorithm {
                        b"ecdsa-sha2-nistp256" => push_ecdsa_scalar(&mut encoded, scalar, 32)?,
                        b"ecdsa-sha2-nistp384" => push_ecdsa_scalar(&mut encoded, scalar, 48)?,
                        b"ecdsa-sha2-nistp521" => push_ecdsa_scalar(&mut encoded, scalar, 66)?,
                        _ => ssh_field(&mut encoded, scalar),
                    }
                }
                let mut reader = encoded.as_slice();
                let key_data = KeypairData::decode(&mut reader).ok()?;
                if !reader.is_finished() {
                    return None;
                }
                key_data
            }
        };
        // Encrypted files may contain up to a block of authenticated random padding.
        let maximum_padding = match self.protection {
            Protection::Plain => 0,
            _ => 16,
        };
        if private_fields.len() > maximum_padding {
            return None;
        }
        let key = PrivateKey::new(key_data, self.comment).ok()?;
        (key.public_key().key_data() == public.key_data()).then_some(key)
    }
}

fn field<'a>(lines: &mut impl Iterator<Item = &'a [u8]>, name: &[u8]) -> Option<&'a [u8]> {
    lines.next()?.strip_prefix(name)
}

fn number<'a>(lines: &mut impl Iterator<Item = &'a [u8]>, name: &[u8], max: u32) -> Option<u32> {
    let raw = field(lines, name)?;
    if !raw.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let value: u32 = std::str::from_utf8(raw).ok()?.parse().ok()?;
    (value > 0 && value <= max).then_some(value)
}

fn block<'a>(
    lines: &mut impl Iterator<Item = &'a [u8]>,
    label: &[u8],
) -> Option<Zeroizing<Vec<u8>>> {
    let count = number(lines, label, MAX_FILE_BYTES as u32)? as usize;
    let mut encoded = Zeroizing::new(Vec::new());
    for _ in 0..count {
        encoded.extend_from_slice(lines.next()?);
    }
    Some(Zeroizing::new(STANDARD.decode(&*encoded).ok()?))
}

fn argon_parameters<'a>(lines: &mut impl Iterator<Item = &'a [u8]>) -> Option<Protection> {
    let algorithm = match field(lines, b"Key-Derivation: ")? {
        b"Argon2d" => ArgonAlgorithm::Argon2d,
        b"Argon2i" => ArgonAlgorithm::Argon2i,
        b"Argon2id" => ArgonAlgorithm::Argon2id,
        _ => return None,
    };
    let memory = number(lines, b"Argon2-Memory: ", MAX_ARGON_MEMORY_KIB)?;
    let passes = number(lines, b"Argon2-Passes: ", MAX_ARGON_PASSES)?;
    let parallelism = number(lines, b"Argon2-Parallelism: ", MAX_ARGON_PARALLELISM)?;
    let salt = hex::decode(field(lines, b"Argon2-Salt: ")?).ok()?;
    let params = Params::new(memory, passes, parallelism, Some(80)).ok()?;
    Some(Protection::AesV3 {
        algorithm,
        params,
        salt,
    })
}

fn decrypt(key: &[u8], iv: &[u8], ciphertext: &mut [u8]) -> Option<()> {
    let cipher = cbc::Decryptor::<Aes256>::new_from_slices(key, iv).ok()?;
    cipher.decrypt_padded_mut::<NoPadding>(ciphertext).ok()?;
    Some(())
}

fn take_ssh_field<'a>(input: &mut &'a [u8]) -> Option<&'a [u8]> {
    let (length, rest) = input.split_first_chunk::<4>()?;
    let (value, rest) = rest.split_at_checked(u32::from_be_bytes(*length) as usize)?;
    *input = rest;
    Some(value)
}

fn ssh_field(buffer: &mut Vec<u8>, value: &[u8]) {
    buffer.extend_from_slice(&(value.len() as u32).to_be_bytes());
    buffer.extend_from_slice(value);
}

fn push_ecdsa_scalar(buffer: &mut Vec<u8>, mpint: &[u8], width: usize) -> Option<()> {
    // Validate the positive SSH mpint before padding it for ssh-key's decoder.
    let magnitude = match mpint {
        [0, next, ..] if *next >= 0x80 => &mpint[1..],
        [first, ..] if (1..0x80).contains(first) => mpint,
        _ => return None,
    };
    let padding = width.checked_sub(magnitude.len())?;
    if padding == 0 {
        ssh_field(buffer, mpint);
    } else {
        buffer.extend_from_slice(&(width as u32).to_be_bytes());
        buffer.resize(buffer.len() + padding, 0);
        buffer.extend_from_slice(magnitude);
    }
    Some(())
}
