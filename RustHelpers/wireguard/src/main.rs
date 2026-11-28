mod ipv6_fragments;
mod stack;
mod tunnel;

use std::fs::{self, File, Permissions};
use std::future::Future;
use std::io::{self, BufReader, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr};
use std::os::unix::{fs::PermissionsExt, net::UnixStream as StdioSocket};
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader as RequestReader};
use tokio::net::{UnixListener, UnixStream, lookup_host};
use tokio::signal::unix::{SignalKind, signal};
use tokio::task::JoinSet;
use tokio::time::timeout;
use zeroize::Zeroizing;

use crate::stack::{MAX_STREAMS, Network, Stream};
use crate::tunnel::{Keys, Tunnel};

const MAX_CONFIG: u64 = 65_536;
const MAX_REQUEST: usize = 4096;
const DIAL_TIMEOUT: Duration = Duration::from_secs(20);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    #[serde(alias = "Proxy")]
    proxy: Proxy,
    #[serde(alias = "Password")]
    password: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Proxy {
    #[serde(alias = "Address")]
    address: String,
    #[serde(alias = "Port")]
    port: u16,
    #[serde(alias = "WireGuard")]
    wire_guard: WireGuard,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireGuard {
    #[serde(alias = "PeerPublicKey")]
    peer_public_key: String,
    #[serde(rename = "localIP", alias = "LocalIP", alias = "localIp")]
    local_ip: String,
    #[serde(alias = "MTU")]
    mtu: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Secrets {
    #[serde(alias = "PrivateKey")]
    private_key: String,
    #[serde(default, alias = "PresharedKey")]
    preshared_key: String,
}

#[derive(Deserialize, Serialize)]
struct Request {
    #[serde(rename = "Target", alias = "target")]
    target: String,
    #[serde(rename = "Port", alias = "port")]
    port: u16,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn key(text: &str) -> io::Result<[u8; 32]> {
    // A 32-byte key has 44 Base64 characters including padding.
    if text.len() != 44 {
        return Err(invalid("invalid WireGuard key"));
    }
    let mut bytes = [0; 32];
    match STANDARD.decode_slice(text, &mut bytes) {
        Ok(32) => Ok(bytes),
        _ => Err(invalid("invalid WireGuard key")),
    }
}

fn local_address(value: &str) -> io::Result<IpAddr> {
    let (address, prefix) = value
        .split_once('/')
        .map_or((value, None), |(ip, prefix)| (ip, Some(prefix)));
    let address: IpAddr = address
        .parse()
        .map_err(|_| invalid("invalid WireGuard tunnel address"))?;
    if let Some(prefix) = prefix {
        let bits = if address.is_ipv4() { 32 } else { 128 };
        if !prefix.parse::<u8>().is_ok_and(|length| length <= bits) {
            return Err(invalid("invalid WireGuard tunnel prefix"));
        }
    }
    Ok(address.to_canonical())
}

fn settings(file: &Path) -> io::Result<(Proxy, Keys)> {
    let source = File::open(file)?;
    let mut raw = Zeroizing::new(Vec::new());
    source.take(MAX_CONFIG + 1).read_to_end(&mut raw)?;
    if raw.len() as u64 > MAX_CONFIG {
        return Err(invalid("WireGuard configuration is too large"));
    }
    let Config { proxy, password } =
        serde_json::from_slice(&raw).map_err(|_| invalid("invalid WireGuard configuration"))?;
    let password = Zeroizing::new(password);
    let Secrets {
        private_key,
        preshared_key,
    } = serde_json::from_str(&password).map_err(|_| invalid("invalid WireGuard credentials"))?;
    let private_key = Zeroizing::new(private_key);
    let preshared_key = Zeroizing::new(preshared_key);
    let keys = Keys {
        private: Zeroizing::new(key(&private_key)?),
        peer: key(&proxy.wire_guard.peer_public_key)?,
        preshared: (!preshared_key.is_empty())
            .then(|| key(&preshared_key).map(Zeroizing::new))
            .transpose()?,
    };
    if !(576..=9000).contains(&proxy.wire_guard.mtu) || proxy.port == 0 {
        return Err(invalid("invalid WireGuard network settings"));
    }
    Ok((proxy, keys))
}

struct SocketPath(PathBuf);

impl Drop for SocketPath {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

async fn serve(file: &Path, socket: &Path) -> io::Result<()> {
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let (proxy, keys) = settings(file)?;
    let endpoint = timeout(
        DIAL_TIMEOUT,
        lookup_host((proxy.address.as_str(), proxy.port)),
    )
    .await??
    .min_by_key(SocketAddr::is_ipv6)
    .ok_or_else(|| invalid("WireGuard peer has no endpoint address"))?;
    let address = local_address(&proxy.wire_guard.local_ip)?;
    let tunnel = Tunnel::start(address, proxy.wire_guard.mtu, endpoint, keys).await?;
    let listener = UnixListener::bind(socket)?;
    let _cleanup = SocketPath(socket.to_owned());
    fs::set_permissions(socket, Permissions::from_mode(0o600))?;
    let shutdown = async {
        tokio::select! {
            _ = terminate.recv() => {}
            _ = interrupt.recv() => {}
        }
    };
    let network = tunnel.network.clone();
    let result = serve_connections(listener, shutdown, move |request| {
        dial(request, network.clone())
    })
    .await;
    tunnel.shutdown().await;
    result
}

async fn serve_connections<Dial, FutureDial, Transport>(
    listener: UnixListener,
    shutdown: impl Future<Output = ()>,
    dial: Dial,
) -> io::Result<()>
where
    Dial: Fn(Request) -> FutureDial + Send + Sync + Clone + 'static,
    FutureDial: Future<Output = io::Result<Transport>> + Send + 'static,
    Transport: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    tokio::pin!(shutdown);
    let mut clients = JoinSet::new();
    let result = loop {
        tokio::select! {
            _ = &mut shutdown => break Ok(()),
            accepted = listener.accept() => {
                let (stream, _) = match accepted {
                    Ok(client) => client,
                    Err(err) => break Err(err),
                };
                if clients.len() < MAX_STREAMS {
                    let dial = dial.clone();
                    clients.spawn(async move { let _ = forward(stream, dial).await; });
                }
            },
            _ = clients.join_next(), if !clients.is_empty() => {}
        }
    };
    drop(listener);
    clients.shutdown().await;
    result
}

async fn forward<Fut, Transport>(
    stream: UnixStream,
    dial: impl FnOnce(Request) -> Fut,
) -> io::Result<()>
where
    Fut: Future<Output = io::Result<Transport>>,
    Transport: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    // Keep this reader for forwarding as it may contain the start of the
    // application stream after its newline-delimited connect request.
    let mut stream = RequestReader::with_capacity(MAX_REQUEST, stream);
    let mut json = Vec::with_capacity(256);
    let count = timeout(
        REQUEST_TIMEOUT,
        (&mut stream)
            .take(MAX_REQUEST as u64)
            .read_until(b'\n', &mut json),
    )
    .await??;
    if count == 0 || json.last() != Some(&b'\n') {
        return Err(invalid("invalid WireGuard connect request"));
    }
    let request: Request =
        serde_json::from_slice(&json).map_err(|_| invalid("invalid WireGuard connect request"))?;
    if request.target.is_empty() || request.port == 0 {
        return Err(invalid("invalid WireGuard connect destination"));
    }
    let mut peer = match timeout(DIAL_TIMEOUT, dial(request)).await {
        Ok(Ok(peer)) => peer,
        _ => {
            stream.write_all(&[1]).await?;
            return Ok(());
        }
    };
    stream.write_all(&[0]).await?;
    tokio::io::copy_bidirectional(&mut stream, &mut peer).await?;
    Ok(())
}

async fn dial(request: Request, network: Network) -> io::Result<Stream> {
    // Resolve through macOS DNS.
    // Only the resulting TCP connection is made inside the userspace stack.
    let candidates = lookup_host((request.target.as_str(), request.port)).await?;
    let mut failure = invalid("WireGuard destination has no addresses");
    for candidate in candidates {
        let target = SocketAddr::new(candidate.ip().to_canonical(), candidate.port());
        match network.connect(target).await {
            Ok(stream) => return Ok(stream),
            Err(err) => failure = err,
        }
    }
    Err(failure)
}

fn connect(socket: &Path, target: &str, port: &str) -> io::Result<()> {
    let port: u16 = port
        .parse()
        .map_err(|_| invalid("invalid WireGuard destination port"))?;
    if port == 0 || target.is_empty() {
        return Err(invalid("invalid WireGuard connect destination"));
    }
    let mut stream = StdioSocket::connect(socket)?;
    stream.set_write_timeout(Some(REQUEST_TIMEOUT))?;
    serde_json::to_writer(
        &mut stream,
        &Request {
            target: target.to_owned(),
            port,
        },
    )?;
    stream.write_all(b"\n")?;
    stream.set_read_timeout(Some(DIAL_TIMEOUT + REQUEST_TIMEOUT))?;
    let mut response = [1];
    // Retain any bytes read beyond the acknowledgment.
    let mut reader = BufReader::new(stream.try_clone()?);
    if reader.read_exact(&mut response).is_err() || response[0] != 0 {
        return Err(io::Error::new(
            io::ErrorKind::ConnectionRefused,
            "peer connection failed",
        ));
    }
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(None)?;
    std::thread::Builder::new()
        .name("wireguard-stdio".into())
        .spawn(move || {
            let _ = io::copy(&mut io::stdin().lock(), &mut stream);
            let _ = stream.shutdown(Shutdown::Write);
        })?;
    let mut output = io::stdout().lock();
    let mut bytes = [0; 16_384];
    loop {
        let count = reader.read(&mut bytes)?;
        if count == 0 {
            return Ok(());
        }
        output.write_all(&bytes[..count])?;
        // OpenSSH's ProxyCommand carries binary packets on a line-buffered pipe.
        output.flush()?;
    }
}

fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    let result = match args.as_slice() {
        [_, action, file, socket] if action == "--serve" => {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .and_then(|runtime| {
                    let result = runtime.block_on(serve(Path::new(file), Path::new(socket)));
                    // A system resolver worker can outlive a cancelled DNS lookup.
                    runtime.shutdown_timeout(Duration::from_millis(100));
                    result
                })
        }
        [_, action, socket, target, port] if action == "--connect" => {
            match (target.to_str(), port.to_str()) {
                (Some(target), Some(port)) => connect(Path::new(socket), target, port),
                _ => Err(invalid("invalid WireGuard connect arguments")),
            }
        }
        _ => Err(invalid("invalid arguments")),
    };
    if let Err(error) = result {
        eprintln!("Termvia: WireGuard connection failed: {error}");
        std::process::exit(1);
    }
}
