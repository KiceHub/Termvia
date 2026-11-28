mod ppk;

use ssh_key::{LineEnding, getrandom::SysRng};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::ExitCode;
use zeroize::Zeroizing;

const MAX_PASSPHRASE_BYTES: usize = 8192;

fn main() -> ExitCode {
    if run().is_some() {
        ExitCode::SUCCESS
    } else {
        eprintln!("Could not convert PPK private key");
        ExitCode::FAILURE
    }
}

fn run() -> Option<()> {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    let [
        source,
        format_flag,
        format,
        output_flag,
        output,
        old_flag,
        old_password,
        new_flag,
        new_password,
    ] = arguments.as_slice()
    else {
        return None;
    };
    if format_flag != "-O"
        || format != "private-openssh-new"
        || output_flag != "-o"
        || old_flag != "--old-passphrase"
        || new_flag != "--new-passphrase"
    {
        return None;
    }

    let input = read_bounded(Path::new(source), ppk::MAX_FILE_BYTES)?;
    let old_password = read_passphrase(Path::new(old_password))?;
    let new_password = read_passphrase(Path::new(new_password))?;
    let mut key = ppk::convert(&input, without_line_ending(&old_password))?;
    let new_password = without_line_ending(&new_password);
    if !new_password.is_empty() {
        key = key.encrypt(&mut SysRng, new_password).ok()?;
    }
    let serialized = key.to_openssh(LineEnding::LF).ok()?;
    write_private_file(Path::new(output), serialized.as_bytes())
}

fn read_bounded(path: &Path, size_limit: usize) -> Option<Zeroizing<Vec<u8>>> {
    let input = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = input.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > size_limit as u64 {
        return None;
    }
    let mut content = Zeroizing::new(Vec::new());
    input
        .take(size_limit as u64 + 1)
        .read_to_end(&mut content)
        .ok()?;
    (content.len() <= size_limit).then_some(content)
}

fn read_passphrase(path: &Path) -> Option<Zeroizing<Vec<u8>>> {
    let contents = read_bounded(path, MAX_PASSPHRASE_BYTES + 2)?;
    let value = without_line_ending(&contents);
    if value.len() > MAX_PASSPHRASE_BYTES
        || value.iter().any(|byte| matches!(byte, b'\r' | b'\n' | 0))
    {
        return None;
    }
    Some(contents)
}

fn without_line_ending(bytes: &[u8]) -> &[u8] {
    if let Some(bytes) = bytes.strip_suffix(b"\n") {
        return bytes.strip_suffix(b"\r").unwrap_or(bytes);
    }
    bytes
}

fn write_private_file(path: &Path, contents: &[u8]) -> Option<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .ok()?;
    if file.write_all(contents).is_err() {
        drop(file);
        let _ = fs::remove_file(path);
        return None;
    }
    Some(())
}
